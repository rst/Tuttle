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

package Tuttle::DdirExtension;

use base 'Tuttle::Extension';
use Data::Dumper;
use strict;

=head2 $ext->dest_prefix( $config_name )

Returns the prefix of all config files what we will be installing.
Files in the given directory which match that prefix, but which aren't
specifically called for in our configuration, will be assumed obsolete
and removed.

=cut

sub dest_prefix {
  my ($self, $config_name) = @_;
  my $class = ref $self;
  die "$class fails to define dest_filename"
}

=head2 $ext->src_filename( $token )

$token is a string denoting a config file to be installed.  Returns
the name of the template containing the source.

=cut

sub src_filename {
  my ($self, $token) = @_;
  my $class = ref $self;
  die "$class fails to define dest_filename"
}

=head2 $ext->activate_file( $file, $was_there )

Invoked after a file was installed, to do anything else necessary
to make sure that it is active.  $was_there is a boolean true if the
file was there already, else false.

Default behavior is to do nothing; this is here to be overridden
by subclasses.

=cut

sub activate_file {
}

=head2 $ext->deactivate_file( $file )

The argument is a file that is no longer current, and is to be
removed.  This routine should do anything necessary to clean up
before the file itself is deleted.

=cut

sub deactivate_file {
}

=head2 $ext->install_extra_args( $file )

Return any extra args (e.g. mode, owner, etc.) appropriate to
install_file_copy for $file, as an options hash for install_file_copy.

=cut

sub install_extra_args {
  return {}
}

=head2 $ext->note_file( $role_config, @tokens )

Notes the @tokens as designating files associated with the role.

Primarily a command handler.

=cut

sub note_file {
  my ($ext, $role_config, @tokens) = @_;
  $role_config->{tokens} ||= [];
  push @{$role_config->{tokens}}, @tokens
}

# Implementations of the standard extension routines, which dispatch
# to the above; the whole point of deriving from DdirExtension is that
# you don't have to worry about any of this stuff...

sub begin_install {
  my ($self) = @_;
  my $config_name = $self->{parent}{config_name};
  my $ipfx  = $self->{parent}{install_prefix}; 
  my $pfx   = $ipfx . $self->dest_prefix($config_name);
  my @files = <${pfx}*>;  # >;  # emacs is confused...
  my %files = map { substr ($_, length $ipfx) => 1 } @files;
  $self->{unclaimed_files} = \%files;
}

sub configure_for_role {
  my ($self, $role_config) = @_;
  my $tokens = $role_config->{tokens};
  return if !defined($tokens);
  foreach my $token (@$tokens) {
    my $config_name = $self->{parent}{config_name};
    my $src_templtoken = $self->src_filename( $token );
    my $src_file = $self->{parent}->locate_config_file( $src_templtoken );
    my $dst_file = $self->dest_prefix( $config_name ) . $token;
    my $dst_file_preexists = (-f $dst_file);
    $self->{parent}->install_file_copy( $src_file, $dst_file,
				        %{$self->install_extra_args} );
    $self->activate_file( $dst_file, $dst_file_preexists );
    delete $self->{unclaimed_files}{$dst_file};
  }
}

sub end_install {
  my ($self) = @_;
  my $unclaimed = $self->{unclaimed_files};
  return if !defined($unclaimed);
  for my $file (keys %$unclaimed) {
    $self->deactivate_file( $file );
    $self->{parent}->remove_file( $file );
  }
}

sub check_role_config {
  my ($self, $role_config) = @_;
  my $parent = $self->{parent};
  my $tokens = $role_config->{tokens};
  foreach my $token( @$tokens) {
    my $src_templtoken = $self->src_filename( $token );
    my $src_file = $self->{parent}->locate_config_file( $src_templtoken );
    $self->{parent}->check_file_keywords( $src_file );
  }
}

1;
