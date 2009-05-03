#! /usr/bin/perl -w

# Written 2005-2008 by Robert S. Thau

#    Tuttle --- Tiny Utility Toolkit for Tweaking Large Environments
#    Copyright (C) 2008  Smartleaf, Inc.
#
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License along
#    with this program; if not, write to the Free Software Foundation, Inc.,
#    51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

=head1 NAME

  Tuttle::Extension -- Abstract base class for all Tuttle extensions

=head1 FUNCTIONS

=cut

package Tuttle::Extension;

use strict;

=head2 Tuttle::Ext_class->new( $config )

Constructor for Tuttle extensions.  Should not be overridden

=cut

sub new {
  my ($proto, $parent) = @_;
  my $class = ref $proto || $proto;
  my $self = bless { parent => $parent }, $class;
  return $self
}

=head2 $ext->begin_install

Routine invoked before any roles associated with the current
configuration have been installed.  Need not do anything; may
collect undo-related status info (e.g., collecting names of
crontabs associated with the current configuration, so we can
remove any that are no longer needed), temporarily shut down
something being retooled, etc.

=cut

sub begin_install {
}

=head2 $ext->configure_for_role( $role_config )

The host is part of this role.  The $role_config is the extension's
configuration info associated with this specific extension.  Set it up.

=cut

sub configure_for_role {
  my ($self) = @_;
  my $ext_name = ref $self;
  die "$ext_name fails to declare configure_for_role"
}

=head2 $ext->end_install

Routine invoked after all roles associated with the current
configuration have been installed.  May restart services, etc.

=cut

sub end_install {
}

=head2 $ext->new_role_config

Returns a new role configuration for the extension.  Generally
just an empty hash.

=cut

sub new_role_config {
  return {}
}

=head2 ExtClass->role_attr_declaration( $cmd, $method )

$method is the name of a method taking arguments as:

  $ext->method( $role_config, @args )

Arranges for that method to be called with those arguments whenever $cmd
is encountered in a role definition; the $role_config should be updated
in some appropriate way.

For example, after

  Tuttle::Cron->role_attr_dclaration( 'crontab', 'note_file' )

a subdeclaration of

  crontab foo bar

within a role declaration will result in an instance of Tuttle::Cron
getting its 'note_file' method invoked via the equivalent of

  $ext->note_file( $role_config, 'foo', 'bar' )

=cut

sub role_attr_declaration {
  my ($class, $cmd, $method) = @_;
  my $handler = $class->can( $method );
  if (!defined ($handler)) {
    die "$class fails to define $method";
  }
  Tuttle::Config->role_attr_declaration( $class, $cmd, $handler );
}

=head2 $ext->check_role_config( $role_config )

Perform any post-parse, pre-config checking of $role_config
that may be useful; for instance, see if all config templates
which $role_config refers to can, in fact, be located

=cut

sub check_role_config {
}

1;
