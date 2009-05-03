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

  Tuttle::DdirExtension -- Abstract base for extensions managing 'foo.d'

=head1 FUNCTIONS

=cut

package Tuttle::OsPackages;

use base 'Tuttle::Extension';
use strict;

sub new_role_config {
  return [];
}

sub add_package {
  my ($self, $role_config, @args) = @_;
  push @$role_config, @args;
}

sub configure_for_role {
  my ($self, $role_config) = @_;
  for my $pkg (@$role_config) {
    my $install_pfx = $self->{parent}{install_prefix};
    my $installer = $install_pfx . '/usr/bin/apt-get';
    $self->{parent}->run_command( $installer, 'install', $pkg );
  }
}

Tuttle::Config->declare_extension( 'Tuttle::OsPackages' );
Tuttle::OsPackages->role_attr_declaration( 'package', 'add_package' );

1;
