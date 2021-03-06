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

  Tuttle::Monconfigs -- Extenstion to handle mon config fragments

=head1 FUNCTIONS

=cut

package Tuttle::Monconfigs;

use base 'Tuttle::DdirExtension';

sub dest_prefix {
  my ($self, $config_name) = @_;
  # TEMPORARY
  return "/etc/mon/modular-config/from_tuttle/${config_name}-"
}

sub src_filename {
  my ($self, $token) = @_;
  return "mon.$token"
}

Tuttle::Config->declare_extension( 'Tuttle::Monconfigs' );
Tuttle::Monconfigs->role_attr_declaration( 'mon_config', 'note_file' );

1;
