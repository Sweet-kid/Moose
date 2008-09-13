
package Moose::Meta::Class;

use strict;
use warnings;

use Class::MOP;

use Carp ();
use List::Util qw( first );
use List::MoreUtils qw( any all );
use Scalar::Util 'weaken', 'blessed';

our $VERSION   = '0.57';
$VERSION = eval $VERSION;
our $AUTHORITY = 'cpan:STEVAN';

use Moose::Meta::Method::Overriden;
use Moose::Meta::Method::Augmented;

use base 'Class::MOP::Class';

__PACKAGE__->meta->add_attribute('roles' => (
    reader  => 'roles',
    default => sub { [] }
));

__PACKAGE__->meta->add_attribute('constructor_class' => (
    accessor => 'constructor_class',
    default  => sub { 'Moose::Meta::Method::Constructor' }
));

__PACKAGE__->meta->add_attribute('destructor_class' => (
    accessor => 'destructor_class',
    default  => sub { 'Moose::Meta::Method::Destructor' }
));

__PACKAGE__->meta->add_attribute('error_builder' => (
    reader  => 'error_builder',
    default => 'confess',
));

__PACKAGE__->meta->add_attribute('error_class' => (
    reader  => 'error_class',
));


sub initialize {
    my $class = shift;
    my $pkg   = shift;
    return Class::MOP::get_metaclass_by_name($pkg) 
        || $class->SUPER::initialize($pkg,
                'attribute_metaclass' => 'Moose::Meta::Attribute',
                'method_metaclass'    => 'Moose::Meta::Method',
                'instance_metaclass'  => 'Moose::Meta::Instance',
                @_
            );    
}

sub create {
    my ($self, $package_name, %options) = @_;
    
    (ref $options{roles} eq 'ARRAY')
        || $self->throw_error("You must pass an ARRAY ref of roles", data => $options{roles})
            if exists $options{roles};
    
    my $class = $self->SUPER::create($package_name, %options);
    
    if (exists $options{roles}) {
        Moose::Util::apply_all_roles($class, @{$options{roles}});
    }
    
    return $class;
}

my %ANON_CLASSES;

sub create_anon_class {
    my ($self, %options) = @_;

    my $cache_ok = delete $options{cache};
    
    # something like Super::Class|Super::Class::2=Role|Role::1
    my $cache_key = join '=' => (
        join('|', sort @{$options{superclasses} || []}),
        join('|', sort @{$options{roles}        || []}),
    );
    
    if ($cache_ok && defined $ANON_CLASSES{$cache_key}) {
        return $ANON_CLASSES{$cache_key};
    }
    
    my $new_class = $self->SUPER::create_anon_class(%options);

    $ANON_CLASSES{$cache_key} = $new_class
        if $cache_ok;

    return $new_class;
}

sub add_role {
    my ($self, $role) = @_;
    (blessed($role) && $role->isa('Moose::Meta::Role'))
        || $self->throw_error("Roles must be instances of Moose::Meta::Role", data => $role);
    push @{$self->roles} => $role;
}

sub calculate_all_roles {
    my $self = shift;
    my %seen;
    grep { !$seen{$_->name}++ } map { $_->calculate_all_roles } @{ $self->roles };
}

sub does_role {
    my ($self, $role_name) = @_;
    (defined $role_name)
        || $self->throw_error("You must supply a role name to look for");
    foreach my $class ($self->class_precedence_list) {
        next unless $class->can('meta') && $class->meta->can('roles');
        foreach my $role (@{$class->meta->roles}) {
            return 1 if $role->does_role($role_name);
        }
    }
    return 0;
}

sub excludes_role {
    my ($self, $role_name) = @_;
    (defined $role_name)
        || $self->throw_error("You must supply a role name to look for");
    foreach my $class ($self->class_precedence_list) {
        next unless $class->can('meta');
        # NOTE:
        # in the pretty rare instance when a Moose metaclass
        # is itself extended with a role, this check needs to
        # be done since some items in the class_precedence_list
        # might in fact be Class::MOP based still.
        next unless $class->meta->can('roles');
        foreach my $role (@{$class->meta->roles}) {
            return 1 if $role->excludes_role($role_name);
        }
    }
    return 0;
}

sub new_object {
    my $class = shift;
    my $params = @_ == 1 ? $_[0] : {@_};
    my $self = $class->SUPER::new_object($params);
    foreach my $attr ($class->compute_all_applicable_attributes()) {
        # if we have a trigger, then ...
        if ($attr->can('has_trigger') && $attr->has_trigger) {
            # make sure we have an init-arg ...
            if (defined(my $init_arg = $attr->init_arg)) {
                # now make sure an init-arg was passes ...
                if (exists $params->{$init_arg}) {
                    # and if get here, fire the trigger
                    $attr->trigger->(
                        $self, 
                        # check if there is a coercion
                        ($attr->should_coerce
                            # and if so, we need to grab the 
                            # value that is actually been stored
                            ? $attr->get_read_method_ref->($self)
                            # otherwise, just get the value from
                            # the constructor params
                            : $params->{$init_arg}), 
                        $attr
                    );
                }
            }       
        }
    }
    return $self;
}

sub construct_instance {
    my $class = shift;
    my $params = @_ == 1 ? $_[0] : {@_};
    my $meta_instance = $class->get_meta_instance;
    # FIXME:
    # the code below is almost certainly incorrect
    # but this is foreign inheritence, so we might
    # have to kludge it in the end.
    my $instance = $params->{'__INSTANCE__'} || $meta_instance->create_instance();
    foreach my $attr ($class->compute_all_applicable_attributes()) {
        $attr->initialize_instance_slot($meta_instance, $instance, $params);
    }
    return $instance;
}

# FIXME:
# This is ugly
sub get_method_map {
    my $self = shift;

    my $current = Class::MOP::check_package_cache_flag($self->name);

    if (defined $self->{'_package_cache_flag'} && $self->{'_package_cache_flag'} == $current) {
        return $self->{'methods'};
    }

    $self->{_package_cache_flag} = $current;

    my $map  = $self->{'methods'};

    my $class_name       = $self->name;
    my $method_metaclass = $self->method_metaclass;

    my %all_code = $self->get_all_package_symbols('CODE');

    foreach my $symbol (keys %all_code) {
        my $code = $all_code{$symbol};

        next if exists  $map->{$symbol} &&
                defined $map->{$symbol} &&
                        $map->{$symbol}->body == $code;

        my ($pkg, $name) = Class::MOP::get_code_info($code);

        if ($pkg->can('meta')
            # NOTE:
            # we don't know what ->meta we are calling
            # here, so we need to be careful cause it
            # just might blow up at us, or just complain
            # loudly (in the case of Curses.pm) so we
            # just be a little overly cautious here.
            # - SL
            && eval { no warnings; blessed($pkg->meta) }
            && $pkg->meta->isa('Moose::Meta::Role')) {
            #my $role = $pkg->meta->name;
            #next unless $self->does_role($role);
        }
        else {
            
            # NOTE:
            # in 5.10 constant.pm the constants show up 
            # as being in the right package, but in pre-5.10
            # they show up as constant::__ANON__ so we 
            # make an exception here to be sure that things
            # work as expected in both.
            # - SL
            unless ($pkg eq 'constant' && $name eq '__ANON__') {
                next if ($pkg  || '') ne $class_name ||
                        (($name || '') ne '__ANON__' && ($pkg  || '') ne $class_name);
            }

        }

        $map->{$symbol} = $method_metaclass->wrap(
            $code,
            package_name => $class_name,
            name         => $symbol
        );
    }

    return $map;
}

### ---------------------------------------------

sub add_attribute {
    my $self = shift;
    $self->SUPER::add_attribute(
        (blessed $_[0] && $_[0]->isa('Class::MOP::Attribute')
            ? $_[0] 
            : $self->_process_attribute(@_))    
    );
}

sub add_override_method_modifier {
    my ($self, $name, $method, $_super_package) = @_;

    (!$self->has_method($name))
        || $self->throw_error("Cannot add an override method if a local method is already present");

    $self->add_method($name => Moose::Meta::Method::Overriden->new(
        method  => $method,
        class   => $self,
        package => $_super_package, # need this for roles
        name    => $name,
    ));
}

sub add_augment_method_modifier {
    my ($self, $name, $method) = @_;
    (!$self->has_method($name))
        || $self->throw_error("Cannot add an augment method if a local method is already present");

    $self->add_method($name => Moose::Meta::Method::Augmented->new(
        method  => $method,
        class   => $self,
        name    => $name,
    ));
}

## Private Utility methods ...

sub _find_next_method_by_name_which_is_not_overridden {
    my ($self, $name) = @_;
    foreach my $method ($self->find_all_methods_by_name($name)) {
        return $method->{code}
            if blessed($method->{code}) && !$method->{code}->isa('Moose::Meta::Method::Overriden');
    }
    return undef;
}

sub _fix_metaclass_incompatibility {
    my ($self, @superclasses) = @_;

    foreach my $super (@superclasses) {
        next if $self->_superclass_meta_is_compatible($super);

        unless ( $self->is_pristine ) {
            $self->throw_error(
                      "Cannot attempt to reinitialize metaclass for "
                    . $self->name
                    . ", it isn't pristine" );
        }

        return $self->_reconcile_with_superclass_meta($super);
    }

    return $self;
}

sub _superclass_meta_is_compatible {
    my ($self, $super) = @_;

    my $super_meta = Class::MOP::Class->initialize($super)
        or return 1;

    next unless $super_meta->isa("Class::MOP::Class");

    my $super_meta_name
        = $super_meta->is_immutable
        ? $super_meta->get_mutable_metaclass_name
        : ref($super_meta);

    return 1
        if $self->isa($super_meta_name)
            and
           $self->instance_metaclass->isa( $super_meta->instance_metaclass );
}

# I don't want to have to type this >1 time
my @MetaClassTypes =
    qw( attribute_metaclass method_metaclass instance_metaclass constructor_class destructor_class );

sub _reconcile_with_superclass_meta {
    my ($self, $super) = @_;

    my $super_meta = $super->meta;

    my $super_metaclass_name
        = $super_meta->is_immutable
        ? $super_meta->get_mutable_metaclass_name
        : ref($super_meta);

    my $self_metaclass = ref $self;

    # If neither of these is true we have a more serious
    # incompatibility that we just cannot fix (yet?).
    if ( $super_metaclass_name->isa( ref $self )
        && all { $super_meta->$_->isa( $self->$_ ) } @MetaClassTypes ) {
        return $self->_reinitialize_with($super_meta);
    }
    elsif ( $self->_all_metaclasses_differ_by_roles_only($super_meta) ) {
        return $self->_reconcile_role_differences($super_meta);
    }

    return $self;
}

sub _reinitialize_with {
    my ( $self, $new_meta ) = @_;

    $self = $new_meta->reinitialize(
        $self->name,
        attribute_metaclass => $new_meta->attribute_metaclass,
        method_metaclass    => $new_meta->method_metaclass,
        instance_metaclass  => $new_meta->instance_metaclass,
    );

    $self->$_( $new_meta->$_ ) for qw( constructor_class destructor_class );

    return $self;
}

# In the more complex case, we share a common ancestor with our
# superclass's metaclass, but each metaclass (ours and the parent's)
# has a different set of roles applied. We reconcile this by first
# reinitializing into the parent class, and _then_ applying our own
# roles.
sub _all_metaclasses_differ_by_roles_only {
    my ($self, $super_meta) = @_;

    for my $pair (
        [ ref $self, ref $super_meta ],
        map { [ $self->$_, $super_meta->$_ ] } @MetaClassTypes
        ) {

        next if $pair->[0] eq $pair->[1];

        my $self_meta_meta  = Class::MOP::Class->initialize( $pair->[0] );
        my $super_meta_meta = Class::MOP::Class->initialize( $pair->[1] );

        my $common_ancestor
            = _find_common_ancestor( $self_meta_meta, $super_meta_meta );

        return unless $common_ancestor;

        return
            unless _is_role_only_subclass_of(
            $self_meta_meta,
            $common_ancestor,
            )
            && _is_role_only_subclass_of(
            $super_meta_meta,
            $common_ancestor,
            );
    }

    return 1;
}

# This, and some other functions, could be called as methods, but
# they're not for two reasons. One, we just end up ignoring the first
# argument, because we can't call these directly on one of the real
# arguments, because one of them could be a Class::MOP::Class object
# and not a Moose::Meta::Class. Second, only a completely insane
# person would attempt to subclass this stuff!
sub _find_common_ancestor {
    my ($meta1, $meta2) = @_;

    # FIXME? This doesn't account for multiple inheritance (not sure
    # if it needs to though). For example, is somewhere in $meta1's
    # history it inherits from both ClassA and ClassB, and $meta
    # inherits from ClassB & ClassA, does it matter? And what crazy
    # fool would do that anyway?

    my %meta1_parents = map { $_ => 1 } $meta1->linearized_isa;

    return first { $meta1_parents{$_} } $meta2->linearized_isa;
}

sub _is_role_only_subclass_of {
    my ($meta, $ancestor) = @_;

    return 1 if $meta->name eq $ancestor;

    my @roles = _all_roles_until( $meta, $ancestor );

    my %role_packages = map { $_->name => 1 } @roles;

    my $ancestor_meta = Class::MOP::Class->initialize($ancestor);

    my %shared_ancestors = map { $_ => 1 } $ancestor_meta->linearized_isa;

    for my $method ( $meta->get_all_methods() ) {
        next if $method->name eq 'meta';
        next if $method->can('associated_attribute');

        next
            if $role_packages{ $method->original_package_name }
                || $shared_ancestors{ $method->original_package_name };

        return 0;
    }

    # FIXME - this really isn't right. Just because an attribute is
    # defined in a role doesn't mean it isn't _also_ defined in the
    # subclass.
    for my $attr ( $meta->get_all_attributes ) {
        next if $shared_ancestors{ $attr->associated_class->name };

        next if any { $_->has_attribute( $attr->name ) } @roles;

        return 0;
    }

    return 1;
}

sub _all_roles {
    my $meta = shift;

    return _all_roles_until($meta);
}

sub _all_roles_until {
    my ($meta, $stop_at_class) = @_;

    return unless $meta->can('calculate_all_roles');

    my @roles = $meta->calculate_all_roles;

    for my $class ( $meta->linearized_isa ) {
        last if $stop_at_class && $stop_at_class eq $class;

        my $meta = Class::MOP::Class->initialize($class);
        last unless $meta->can('calculate_all_roles');

        push @roles, $meta->calculate_all_roles;
    }

    return @roles;
}

sub _reconcile_role_differences {
    my ($self, $super_meta) = @_;

    my $self_meta = $self->meta;

    my %roles;

    if ( my @roles = map { $_->name } _all_roles($self_meta) ) {
        $roles{metaclass_roles} = \@roles;
    }

    for my $thing (@MetaClassTypes) {
        my $name = $self->$thing();

        my $thing_meta = Class::MOP::Class->initialize($name);

        my @roles = map { $_->name } _all_roles($thing_meta)
            or next;

        $roles{ $thing . '_roles' } = \@roles;
    }

    $self = $self->_reinitialize_with($super_meta);

    Moose::Util::MetaRole::apply_metaclass_roles(
        for_class => $self->name,
        %roles,
    );

    return $self;
}

# NOTE:
# this was crap anyway, see
# Moose::Util::apply_all_roles
# instead
sub _apply_all_roles { 
    Carp::croak 'DEPRECATED: use Moose::Util::apply_all_roles($meta, @roles) instead' 
}

sub _process_attribute {
    my ( $self, $name, @args ) = @_;

    @args = %{$args[0]} if scalar @args == 1 && ref($args[0]) eq 'HASH';

    if ($name =~ /^\+(.*)/) {
        return $self->_process_inherited_attribute($1, @args);
    }
    else {
        return $self->_process_new_attribute($name, @args);
    }
}

sub _process_new_attribute {
    my ( $self, $name, @args ) = @_;

    $self->attribute_metaclass->interpolate_class_and_new($name, @args);
}

sub _process_inherited_attribute {
    my ($self, $attr_name, %options) = @_;
    my $inherited_attr = $self->find_attribute_by_name($attr_name);
    (defined $inherited_attr)
        || $self->throw_error("Could not find an attribute by the name of '$attr_name' to inherit from", data => $attr_name);
    if ($inherited_attr->isa('Moose::Meta::Attribute')) {
        return $inherited_attr->clone_and_inherit_options(%options);
    }
    else {
        # NOTE:
        # kind of a kludge to handle Class::MOP::Attributes
        return $inherited_attr->Moose::Meta::Attribute::clone_and_inherit_options(%options);
    }
}

## -------------------------------------------------

use Moose::Meta::Method::Constructor;
use Moose::Meta::Method::Destructor;

# This could be done by using SUPER and altering ->options
# I am keeping it this way to make it more explicit.
sub create_immutable_transformer {
    my $self = shift;
    my $class = Class::MOP::Immutable->new($self, {
       read_only   => [qw/superclasses/],
       cannot_call => [qw/
           add_method
           alias_method
           remove_method
           add_attribute
           remove_attribute
           remove_package_symbol
           add_role
       /],
       memoize     => {
           class_precedence_list             => 'ARRAY',
           linearized_isa                    => 'ARRAY', # FIXME perl 5.10 memoizes this on its own, no need?
           get_all_methods                   => 'ARRAY',
           #get_all_attributes               => 'ARRAY', # it's an alias, no need, but maybe in the future
           compute_all_applicable_attributes => 'ARRAY',
           get_meta_instance                 => 'SCALAR',
           get_method_map                    => 'SCALAR',
           calculate_all_roles               => 'ARRAY',
       },
       # NOTE:
       # this is ugly, but so are typeglobs, 
       # so whattayahgonnadoboutit
       # - SL
       wrapped => { 
           add_package_symbol => sub {
               my $original = shift;
               $self->throw_error("Cannot add package symbols to an immutable metaclass")
                   unless (caller(2))[3] eq 'Class::MOP::Package::get_package_symbol'; 
               goto $original->body;
           },
       },       
    });
    return $class;
}

sub make_immutable {
    my $self = shift;
    $self->SUPER::make_immutable
      (
       constructor_class => $self->constructor_class,
       destructor_class  => $self->destructor_class,
       inline_destructor => 1,
       # NOTE:
       # no need to do this,
       # Moose always does it
       inline_accessors  => 0,
       @_,
      );
}

#{ package Moose::Meta::Class::ErrorRoutines; %Carp::Internal?

our $level;

sub throw_error {
    my ( $self, @args ) = @_;
    local $level = 1;
    $self->raise_error($self->create_error(@args));
}

sub raise_error {
    my ( $self, @args ) = @_;
    die @args;
}

sub create_error {
    my ( $self, @args ) = @_;

    if ( @args % 2 == 1 ) {
        unshift @args, "message";
    }

    my %args = ( meta => $self, error => $@, @args );

    local $level = $level + 1;

    if ( my $class = $args{class} || ( ref $self && $self->error_class ) ) {
        return $self->create_error_object( %args, class => $class );
    } else {
        my $builder = $args{builder} || ( ref($self) ? $self->error_builder : "confess" );

        my $builder_method = ( ( ref($builder) && ref($builder) eq 'CODE' ) 
            ? $builder
            : ( $self->can("create_error_$builder") || "create_error_confess" ));

        return $self->$builder_method(%args);
    }
}

sub create_error_object {
    my ( $self, %args ) = @_;

    my $class = delete $args{class};

    $class->new(
        %args,
        depth => ( ($args{depth} || 1) + ( $level + 1 ) ),
    );
}

sub create_error_croak {
    my ( $self, @args ) = @_;
    $self->_create_error_carpmess( @args );
}

sub create_error_confess {
    my ( $self, @args ) = @_;
    $self->_create_error_carpmess( @args, longmess => 1 );
}

sub _create_error_carpmess {
    my ( $self, %args ) = @_;

    my $carp_level = $level + 1 + ( $args{depth} || 1 );

    local $Carp::CarpLevel = $carp_level; # $Carp::CarpLevel + $carp_level ?
    local $Carp::MaxArgNums = 20;         # default is 8, usually we use named args which gets messier though

    my @args = exists $args{message} ? $args{message} : ();

    if ( $args{longmess} ) {
        return Carp::longmess(@args);
    } else {
        return Carp::shortmess(@args);
    }
}

1;

__END__

=pod

=head1 NAME

Moose::Meta::Class - The Moose metaclass

=head1 DESCRIPTION

This is a subclass of L<Class::MOP::Class> with Moose specific
extensions.

For the most part, the only time you will ever encounter an
instance of this class is if you are doing some serious deep
introspection. To really understand this class, you need to refer
to the L<Class::MOP::Class> documentation.

=head1 METHODS

=over 4

=item B<initialize>

=item B<create>

Overrides original to accept a list of roles to apply to
the created class.

   my $metaclass = Moose::Meta::Class->create( 'New::Class', roles => [...] );

=item B<create_anon_class>

Overrides original to support roles and caching.

   my $metaclass = Moose::Meta::Class->create_anon_class(
       superclasses => ['Foo'],
       roles        => [qw/Some Roles Go Here/],
       cache        => 1,
   );

=item B<make_immutable>

Override original to add default options for inlining destructor
and altering the Constructor metaclass.

=item B<create_immutable_transformer>

Override original to lock C<add_role> and memoize C<calculate_all_roles>

=item B<new_object>

We override this method to support the C<trigger> attribute option.

=item B<construct_instance>

This provides some Moose specific extensions to this method, you
almost never call this method directly unless you really know what
you are doing.

This method makes sure to handle the moose weak-ref, type-constraint
and type coercion features.

=item B<get_method_map>

This accommodates Moose::Meta::Role::Method instances, which are
aliased, instead of added, but still need to be counted as valid
methods.

=item B<add_override_method_modifier ($name, $method)>

This will create an C<override> method modifier for you, and install
it in the package.

=item B<add_augment_method_modifier ($name, $method)>

This will create an C<augment> method modifier for you, and install
it in the package.

=item B<calculate_all_roles>

=item B<roles>

This will return an array of C<Moose::Meta::Role> instances which are
attached to this class.

=item B<add_role ($role)>

This takes an instance of C<Moose::Meta::Role> in C<$role>, and adds it
to the list of associated roles.

=item B<does_role ($role_name)>

This will test if this class C<does> a given C<$role_name>. It will
not only check it's local roles, but ask them as well in order to
cascade down the role hierarchy.

=item B<excludes_role ($role_name)>

This will test if this class C<excludes> a given C<$role_name>. It will
not only check it's local roles, but ask them as well in order to
cascade down the role hierarchy.

=item B<add_attribute ($attr_name, %params|$params)>

This method does the same thing as L<Class::MOP::Class::add_attribute>, but adds
support for taking the C<$params> as a HASH ref.

=item B<constructor_class ($class_name)>

=item B<destructor_class ($class_name)>

These are the names of classes used when making a class
immutable. These default to L<Moose::Meta::Method::Constructor> and
L<Moose::Meta::Method::Destructor> respectively. These accessors are
read-write, so you can use them to change the class name.

=item B<throw_error $message, %extra>

Throws the error created by C<create_error> using C<raise_error>

=item B<create_error $message, %extra>

Creates an error message or object.

The default behavior is C<create_error_confess>.

If C<error_class> is set uses C<create_error_object>. Otherwise uses
C<error_builder> (a code reference or variant name), and calls the appropriate
C<create_error_$builder> method.

=item B<error_builder $builder_name>

Get or set the error builder. Defaults to C<confess>.

=item B<error_class $class_name>

Get or set the error class. Has no default.

=item B<create_error_confess %args>

Creates an error using L<Carp/longmess>

=item B<create_error_croak %args>

Creates an error using L<Carp/shortmess>

=item B<create_error_object %args>

Calls C<new> on the C<class> parameter in C<%args>. Usable with C<error_class>
to support custom error objects for your meta class.

=item B<raise_error $error>

Dies with an error object or string.

=back

=head1 BUGS

All complex software has bugs lurking in it, and this module is no
exception. If you find a bug please either email me, or add the bug
to cpan-RT.

=head1 AUTHOR

Stevan Little E<lt>stevan@iinteractive.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2006-2008 by Infinity Interactive, Inc.

L<http://www.iinteractive.com>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

