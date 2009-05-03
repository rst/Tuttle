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

  Tuttle::Apache2Vhosts -- Extenstion to handle Apache 2 virtual hosts

=head1 FUNCTIONS

=cut

package Tuttle::Apache2Vhosts;

use base 'Tuttle::DdirExtension';

sub dest_prefix {
  my ($self, $config_name) = @_;
  return "/etc/apache2/sites-available/${config_name}_"
}

sub src_filename {
  my ($self, $token) = @_;
  return "vhost.$token"
}

sub activate_file {
  my ($self, $filename) = @_;
  symlink $filename, $self->link_loc($filename);
  $self->{something_changed} = 1;
}

sub deactivate_file {
  my ($self, $filename) = @_;
  unlink $self->link_loc($filename);
  $self->{something_changed} = 1;
}

sub end_install {
  my ($self) = @_;
  $self->SUPER::end_install;
  if ($self->{something_changed}) {
    system( "/usr/sbin/apache2ctl graceful" );
  }
}

sub link_loc {
  my ($self, $filename) = @_;
  my $basename = $filename;
  $basename =~ s|.*/||;
  return "/etc/apache2/sites-enabled/$basename";
}

Tuttle::Config->declare_extension( 'Tuttle::Apache2Vhosts' );
Tuttle::Apache2Vhosts->role_attr_declaration( 'vhost', 'note_file' );

1;
