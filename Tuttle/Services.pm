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

  Tuttle::Services -- Extenstion to handle services

=head1 FUNCTIONS

=cut

package Tuttle::Services;

use base 'Tuttle::DdirExtension';
use strict;

sub dest_prefix {
  my ($self, $config_name) = @_;
  my $srv_dir = $self->service_file_dir;
  return "$srv_dir/$config_name."
}

sub src_filename {
  my ($self, $token) = @_;
  return "service.$token"
}

sub install_extra_args {
  my ($self) = @_;
  return { mode => '0755' }
}

sub activate_file {
  my ($self, $filename, $was_there) = @_;
  my ($basename) = $filename;
  my $was_tok = $was_there ? "Reactivating" : "Activating";
  print "$was_tok '${filename}'\n";
  $basename =~ s|.*/||;
  $self->create_service_links ($basename);
  $self->{parent}->run_command ($self->{parent}{install_prefix} . $filename,
				($was_there ? "restart" : "start"));
}

sub deactivate_file {
  my ($self, $filename) = @_;
  my ($basename) = $filename;
  $basename =~ s|.*/||;
  $self->{parent}->run_command ($self->{parent}{install_prefix} . $filename,
				"stop");
  $self->remove_service_links ($basename);
}

sub service_file_dir {
  my ($self) = @_;
  for my $candidate (qw(/etc/rc.d/init.d /etc/init.d /etc/rc.d)) {
    if (-d $self->{parent}{install_prefix} . $candidate) {
      return $candidate;
    }
  }

  die "Could not find service (init.d file) directory!"
}

sub create_service_links {
  my ($self, $service_name) = @_;
  my $chkconfig  = $self->{parent}{install_prefix} . '/sbin/chkconfig';
  my $rcd_update = $self->{parent}{install_prefix} . '/usr/sbin/update-rc.d';
  if (-x $chkconfig) {
    $self->{parent}->run_command ($chkconfig, $service_name, "on");
  }
  elsif (-x $rcd_update) {
    $self->{parent}->run_command ($rcd_update, $service_name, "defaults");
  }
  else {
    print STDERR "Unable to create links for $service_name; could not find service link editor\n";
  }
}

sub remove_service_links {
  my ($self, $service_name) = @_;
  my $chkconfig  = $self->{parent}{install_prefix} . '/sbin/chkconfig';
  my $rcd_update = $self->{parent}{install_prefix} . '/usr/sbin/update-rc.d';
  if (-x $chkconfig) {
    $self->{parent}->run_command ($chkconfig, $service_name, "off");
  }
  elsif (-x $rcd_update) {
    $self->{parent}->run_command ($rcd_update, "-f", $service_name, "remove");
  }
  else {
    print STDERR "Unable to remove links for $service_name; could not find service link editor\n";
  }
}

Tuttle::Config->declare_extension( 'Tuttle::Services' );
Tuttle::Services->role_attr_declaration( 'service', 'note_file' );

1;
