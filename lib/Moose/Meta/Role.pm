package Moose::Meta::Role;

use strict;
use warnings;
use metaclass;

use Carp         'confess';
use Scalar::Util 'blessed';
use B            'svref_2object';

use Moose::Meta::Class;

our $VERSION = '0.04';

## Attributes

## the meta for the role package

__PACKAGE__->meta->add_attribute('_role_meta' => (
    reader   => '_role_meta',
    init_arg => ':role_meta'
));

## roles

__PACKAGE__->meta->add_attribute('roles' => (
    reader  => 'get_roles',
    default => sub { [] }
));

## excluded roles

__PACKAGE__->meta->add_attribute('excluded_roles_map' => (
    reader  => 'get_excluded_roles_map',
    default => sub { {} }
));

## attributes

__PACKAGE__->meta->add_attribute('attribute_map' => (
    reader   => 'get_attribute_map',
    default  => sub { {} }
));

## required methods

__PACKAGE__->meta->add_attribute('required_methods' => (
    reader  => 'get_required_methods_map',
    default => sub { {} }
));

## Methods 

sub new {
    my $class   = shift;
    my %options = @_;
    $options{':role_meta'} = Moose::Meta::Class->initialize(
        $options{role_name},
        ':method_metaclass' => 'Moose::Meta::Role::Method'
    ) unless defined $options{':role_meta'} && 
             $options{':role_meta'}->isa('Moose::Meta::Class');
    my $self = $class->meta->new_object(%options);
    return $self;
}

## subroles

sub add_role {
    my ($self, $role) = @_;
    (blessed($role) && $role->isa('Moose::Meta::Role'))
        || confess "Roles must be instances of Moose::Meta::Role";
    push @{$self->get_roles} => $role;
}

sub calculate_all_roles {
    my $self = shift;
    my %seen;
    grep { !$seen{$_->name}++ } $self, map { $_->calculate_all_roles } @{ $self->get_roles };
}

sub does_role {
    my ($self, $role_name) = @_;
    (defined $role_name)
        || confess "You must supply a role name to look for";
    # if we are it,.. then return true
    return 1 if $role_name eq $self->name;
    # otherwise.. check our children
    foreach my $role (@{$self->get_roles}) {
        return 1 if $role->does_role($role_name);
    }
    return 0;
}

## excluded roles

sub add_excluded_roles {
    my ($self, @excluded_role_names) = @_;
    $self->get_excluded_roles_map->{$_} = undef foreach @excluded_role_names;
}

sub get_excluded_roles_list {
    my ($self) = @_;
    keys %{$self->get_excluded_roles_map};
}

sub excludes_role {
    my ($self, $role_name) = @_;
    exists $self->get_excluded_roles_map->{$role_name} ? 1 : 0;
}

## required methods

sub add_required_methods {
    my ($self, @methods) = @_;
    $self->get_required_methods_map->{$_} = undef foreach @methods;
}

sub remove_required_methods {
    my ($self, @methods) = @_;
    delete $self->get_required_methods_map->{$_} foreach @methods;
}

sub get_required_method_list {
    my ($self) = @_;
    keys %{$self->get_required_methods_map};
}

sub requires_method {
    my ($self, $method_name) = @_;
    exists $self->get_required_methods_map->{$method_name} ? 1 : 0;
}

sub _clean_up_required_methods {
    my $self = shift;
    foreach my $method ($self->get_required_method_list) {
        $self->remove_required_methods($method)
            if $self->has_method($method);
    } 
}

## methods

# NOTE:
# we delegate to some role_meta methods for convience here
# the Moose::Meta::Role is meant to be a read-only interface
# to the underlying role package, if you want to manipulate 
# that, just use ->role_meta

sub name    { (shift)->_role_meta->name    }
sub version { (shift)->_role_meta->version }

sub get_method          { (shift)->_role_meta->get_method(@_)         }
sub find_method_by_name { (shift)->_role_meta->find_method_by_name(@_) }
sub has_method          { (shift)->_role_meta->has_method(@_)         }
sub alias_method        { (shift)->_role_meta->alias_method(@_)       }
sub get_method_list { 
    my ($self) = @_;
    grep { 
        # NOTE:
        # this is a kludge for now,... these functions 
        # should not be showing up in the list at all, 
        # but they do, so we need to switch Moose::Role
        # and Moose to use Sub::Exporter to prevent this
        !/^(meta|has|extends|blessed|confess|augment|inner|override|super|before|after|around|with|requires)$/ 
    } $self->_role_meta->get_method_list;
}

# ... however the items in statis (attributes & method modifiers)
# can be removed and added to through this API

# attributes

my $id;
sub add_attribute {
    my $self      = shift;
    # either we have an attribute object already
    # or we need to create one from the args provided
    require Moose::Meta::Attribute;
    my $attribute = blessed($_[0]) ? $_[0] : $self->_role_meta->attribute_metaclass->new(@_);
    # make sure it is derived from the correct type though
    ($attribute->isa('Class::MOP::Attribute'))
        || confess "Your attribute must be an instance of Class::MOP::Attribute (or a subclass)";    
    $attribute->attach_to_class($self->_role_meta);
    # FIXME attribute vs. method shadowing # $attribute->install_accessors();
    $self->get_attribute_map->{$attribute->name} = $attribute;

    $attribute->{__id} ||= ++$id;

    $self->remove_required_methods(
        grep { defined }
            map { $attribute->$_ }
                qw/accessor reader writer/
    );

	# FIXME
	# in theory we have to tell everyone the slot structure may have changed
}

sub has_attribute {
    my ($self, $attribute_name) = @_;
    (defined $attribute_name && $attribute_name)
        || confess "You must define an attribute name";
    exists $self->get_attribute_map->{$attribute_name} ? 1 : 0;    
} 

sub get_attribute {
    my ($self, $attribute_name) = @_;
    (defined $attribute_name && $attribute_name)
        || confess "You must define an attribute name";
    return $self->get_attribute_map->{$attribute_name} 
        if $self->has_attribute($attribute_name);   
    return; 
}

sub remove_attribute {
    my ($self, $attribute_name) = @_;
    (defined $attribute_name && $attribute_name)
        || confess "You must define an attribute name";
    my $removed_attribute = $self->get_attribute_map->{$attribute_name};    
    return unless defined $removed_attribute;
    delete $self->get_attribute_map->{$attribute_name};        
    $removed_attribute->remove_accessors(); 
    $removed_attribute->detach_from_class();
    return $removed_attribute;
} 

sub get_attribute_list {
    my ($self) = @_;
    keys %{$self->get_attribute_map};
}

sub compute_all_applicable_attributes {
    my $self = shift;
    my @attrs;

    my %attrs;

    foreach my $role (@{ $self->get_roles() }) {
        foreach my $attr ( $role->compute_all_applicable_attributes ) {
            push @{ $attrs{$attr->name} ||= [] }, $attr;
        }
    }

    # remove all conflicting attributes
    foreach my $attr_name ( keys %attrs ) {
        if ( @{ $attrs{$attr_name} } == 1 ) {
            $attrs{$attr_name} = $attrs{$attr_name}[0];
        } else {
            delete $attrs{$attr_name};
        }
    }

    # overlay our own attributes
    my @local_attr_list = $self->get_attribute_list;
    @attrs{@local_attr_list} = map { $self->get_attribute($_) } @local_attr_list;

    return values %attrs;
}

sub find_attribute_by_name {
    my ($self, $attr_name) = @_;
    # keep a record of what we have seen
    # here, this will handle all the 
    # inheritence issues because we are 
    # using the &class_precedence_list

    if ( $self->has_attribute( $attr_name ) ) {
        return $self->get_attribute( $attr_name );
    } else {
        my @found;
        foreach my $role ( @{ $self->get_roles } ) {
            if ( my $attr = $role->find_attribute_by_name ) {
                push @found, $attr;
            }
        }

        if ( @found == 1 ) {
            # there's no conflict
            return $found[0];
        } else {
            return;
        }
    }
}

## applying a role to a class ...

sub _check_excluded_roles {
    my ($self, $other) = @_;
    if ($other->excludes_role($self->name)) {
        confess "Conflict detected: " . $other->name . " excludes role '" . $self->name . "'";
    }
    foreach my $excluded_role_name ($self->get_excluded_roles_list) {
        if ($other->does_role($excluded_role_name)) { 
            confess "The class " . $other->name . " does the excluded role '$excluded_role_name'";
        }
        else {
            if ($other->isa('Moose::Meta::Role')) {
                $other->add_excluded_roles($excluded_role_name);
            }
            # else -> ignore it :) 
        }
    }    
}

sub _check_required_methods {
    my ($self, $other) = @_;
    # NOTE:
    # we might need to move this down below the 
    # the attributes so that we can require any 
    # attribute accessors. However I am thinking 
    # that maybe those are somehow exempt from 
    # the require methods stuff.  

    ### FIXME
    # attributes' accessors are not being treated as first class methods as far as role composition is concerned.

    foreach my $required_method_name ($self->get_required_method_list) {
        
        unless ($other->find_method_by_name($required_method_name)) {
            if ($other->isa('Moose::Meta::Role')) {
                $other->add_required_methods($required_method_name);
            }
            else {
                confess "'" . $self->name . "' requires the method '$required_method_name' " . 
                        "to be implemented by '" . $other->name . "'";
            }
        }
    }    
}

sub _apply_attributes {
    my ($self, $other) = @_;    
    foreach my $attr ($self->compute_all_applicable_attributes) {
        # it if it has one already
        my $other_attr = $other->find_attribute_by_name($attr->name);

        # __id is a hack to allow cloned attrs to compare as equal
        if ( $other_attr && !(( exists ($other_attr->{__id}) && exists($other_attr->{__id}) && $other_attr->{__id} == $attr->{__id} ) || $other_attr == $attr ) ) { 
            # see if we are being composed  
            # into a role or not
            if ($other->isa('Moose::Meta::Role')) {                
                # all attribute conflicts between roles 
                # result in an immediate fatal error 
                # FIXME - do they
                confess "Role '" . $self->name . "' has encountered an attribute conflict " . 
                        "during composition. This is fatal error and cannot be disambiguated.";
            }
            else {
                # but if this is a class, we 
                # can safely skip adding the 
                # attribute to the class
                next;
            }
        }
        else {
            my $clone = $attr->meta->clone_object( $attr );
            $other->add_attribute( $clone );
        }
    }    
}

sub _apply_methods {
    my ($self, $other) = @_;   
    foreach my $method_name ($self->get_method_list) {
        # it if it has one already
        my $other_method = $other->find_method_by_name($method_name);
        if ($other_method && $other_method != $self->get_method($method_name)) {
            # see if we are composing into a role
            if ($other->isa('Moose::Meta::Role')) { 
                # method conflicts between roles result 
                # in the method becoming a requirement
                $other->add_required_methods($method_name);
                # NOTE:
                # we have to remove the method from our 
                # role, if this is being called from combine()
                # which means the meta is an anon class
                # this *may* cause problems later, but it 
                # is probably fairly safe to assume that 
                # anon classes will only be used internally
                # or by people who know what they are doing
                $other->_role_meta->remove_method($method_name)
                    if $other->_role_meta->name =~ /__ANON__/;
            }
            else {
                next;
            }
        }
        else {
            # add it, although it could be overriden 
            $other->alias_method(
                $method_name,
                $self->get_method($method_name)
            );
        }
    }     
}

sub apply {
    my ($self, $other) = @_;
    
    ($other->isa('Moose::Meta::Class') || $other->isa('Moose::Meta::Role'))
        || confess "You must apply a role to a metaclass, not ($other)";
    
    $self->_check_excluded_roles($other);
    $self->_check_required_methods($other);  

    $self->_apply_attributes($other);         
    $self->_apply_methods($other);         

    $other->add_role($self);
}

sub combine {
    my ($class, @roles) = @_;
    
    my $combined = $class->new(
        ':role_meta' => Moose::Meta::Class->create_anon_class()
    );
    
    foreach my $role (@roles) {
        $role->apply($combined);
    }
    
    $combined->_clean_up_required_methods;   
    
    return $combined;
}

package Moose::Meta::Role::Method;

use strict;
use warnings;

our $VERSION = '0.01';

use base 'Class::MOP::Method';

1;

__END__

=pod

=head1 NAME

Moose::Meta::Role - The Moose Role metaclass

=head1 DESCRIPTION

Moose's Roles are being actively developed, please see L<Moose::Role> 
for more information. For the most part, this has no user-serviceable 
parts inside. It's API is still subject to some change (although 
probably not that much really).

=head1 METHODS

=over 4

=item B<meta>

=item B<new>

=item B<apply>

=item B<combine>

=back

=over 4

=item B<name>

=item B<version>

=item B<role_meta>

=back

=over 4

=item B<get_roles>

=item B<add_role>

=item B<does_role>

=back

=over 4

=item B<add_excluded_roles>

=item B<excludes_role>

=item B<get_excluded_roles_list>

=item B<get_excluded_roles_map>

=item B<calculate_all_roles>

=back

=over 4

=item B<find_method_by_name>

=item B<get_method>

=item B<has_method>

=item B<alias_method>

=item B<get_method_list>

=back

=over 4

=item B<add_attribute>

=item B<has_attribute>

=item B<get_attribute>

=item B<get_attribute_list>

=item B<get_attribute_map>

=item B<remove_attribute>

=back

=over 4

=item B<add_required_methods>

=item B<remove_required_methods>

=item B<get_required_method_list>

=item B<get_required_methods_map>

=item B<requires_method>

=back

=head1 BUGS

All complex software has bugs lurking in it, and this module is no 
exception. If you find a bug please either email me, or add the bug
to cpan-RT.

=head1 AUTHOR

Stevan Little E<lt>stevan@iinteractive.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2006 by Infinity Interactive, Inc.

L<http://www.iinteractive.com>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself. 

=cut
