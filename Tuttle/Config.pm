#! /usr/bin/perl -w

# Written 2005-2008 by Robert S. Thau

#    Tuttle --- Tiny Utility Toolkit for Tweaking Large Environments
#    Copyright (C) 2005-2008  Smartleaf, Inc.
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

package Tuttle::Config;

require Exporter;

use IO::File;
use File::Path;
use File::Basename;
use File::Spec;
use File::Find;
use strict;

our @extensions;
our %ext_decls;

sub declare_extension {
  my ($self, $ext) = @_;
  push @extensions, $ext;
}

sub role_attr_declaration {
  my ($class, $ext_class, $cmd, $handler) = @_;
  $ext_decls{$cmd} = { ext => $ext_class, handler => $handler };
}

use Tuttle::OsPackages;
use Tuttle::Crontabs;
use Tuttle::Services;
use Tuttle::Apache2Vhosts;

=head1 NAME

  Tuttle::Config -- Tiny Utility Toolkit for Tweaking Large Environments

=head1 SYNOPSIS

  Typically run from /etc/cron.d/tuttle_master_job, which invokes

    perl /gold/tuttle/bin/tuttle-master-job

  or directly to update a host's configuration for a particular environment:

    perl /gold/tuttle/bin/configure-for $environment_name

  which is, effectively, a wrapper around this:

    use lib '/gold/tuttle';
    use Tuttle::Config;

    chdir '/gold/tuttle';
    for my $dir (@ARGV) {
      Tuttle::Config->new ($dir, "$dir/Roles.conf")->install;
    }

  There are programmatic interfaces to the routines which install
  individual crontabs, services, etc.; these are documented here as
  well, but are exposed mainly for Tuttle's own test suite.

=head1 DESCRIPTION

This is a tool for managing the configuration of a group of machines
as a unit.  It is currently somewhat specialized to Smartleaf's needs,
and is designed to be somewhat easier to use than our last generation
of such tools (symlinker).

The basic idea is that the configuration file for server farm 'fubar'
(stored in /gold/fubar/Tuttle) declares a number of roles, and
assigns hosts to one or more roles.  When asked to do setup, a
Tuttle::Config object figures out what host it's running on, and
which roles that host has been assigned to.  It then makes sure that
the host has the crontabs and services (/etc/rc.d) files associated
with those roles, and *only* those roles, and arranges for the
installation of associated software.

A host assigned to no roles will have all crontabs associated with
this server pool removed, and all services associated with it shut
down and deleted.  If it is assigned to the special role "wipeout",
software installations, spool and log directories associated with
the server pool will also be deleted.  This is intended to allow us
to uninstall test releases from temporary server pools quickly and
easily.

Installed crontabs and services are effectively tagged with the name of
the configuration, making it possible for a subsequent Tuttle run to
rearrange or remove them if the host is reassigned to different roles.


=head1 FUNCTIONS

=head2 Tuttle::Config->new ($config_name, $filename [, $phony_root])

Read in the configuration for server pool $config_name from gold,
and return an object that encapsulates the configuration it
describes.

The optional second argument allows you to give a phony root
directory for testing purposes; this is strictly a testing hook.

=cut

sub new {
  my ($proto, $config_name, $filename, $phony_root) = @_;
  my $class = ref $proto || $proto;
  my $self = bless {}, $class;

  $self->{config_name} = $config_name;
  $self->{basename} = File::Spec->rel2abs (dirname $filename);
  $self->{roles} = {};
  $self->{keywords} = { id => $config_name };
  $self->{install_prefix} = $phony_root || '';
  $self->{fake_mode} = defined $phony_root;
  $self->{config_search_path} = undef;
  $self->{install_record} = undef;
  $self->{extensions} = [map { $_->new($self) } @extensions];

  # Reasons we can't use this config, even if we could parse it...

  $self->{config_spec_errors} = [];

  $self->parse ($filename);
  return $self;
}

=head2 $config->disable

Mark this configuration as 'disabled' on this host.  (This is
currently implemented by creating a file with the same name as
the configuration in directory '/var/lock/tuttle-disables'.)

When installing a configuration on a host where it has been
disabled ($config->install, q.v.), nothing is actually installed,
and all previously configured services, crontabs, etc., associated
with the configuration are removed, whether they would otherwise
belong on the machine or not.

This is intended to allow temporary shutdowns for maintenance.

=cut

sub disable {
  my ($self) = @_;
  mkpath( $self->disable_dir, 0, 0755 );
  my ($fh) = IO::File->new( $self->disable_path, 'w' );
  if (!defined( $fh )) {
    die "Could not create flag file to disable"
  }
  $fh->close
}

sub disable_dir {
  my ($self) = @_;
  return $self->{install_prefix} . '/var/lock/tuttle-disables/'
}

sub disable_path {
  my ($self) = @_;
  return $self->disable_dir . '/' . $self->{config_name}
}

=head2 $config->enable

Mark this config as 'enabled'

Undo the effects of $config->disable.

=cut

sub enable {
  my ($self) = @_;
  if ((-f $self->disable_path) && unlink($self->disable_path) != 1) {
    die "Could not remove flag file to enable"
  }
}

=head2 $config->is_disabled

Returns true if this configuration is disabled on this host.

=cut

sub is_disabled {
  my ($self) = @_;
  return( -f $self->disable_path )
}

=head2 $config->install ($hostname, $hostname, ...)

Install the configuration for hosts with any of the names $hostnames.
The defaults for this are the output of `hostname -s`, `hostname -f`,
and `hostname -a`; this allows the host to be referred to by any of
its names in a Roles.conf file.

Installs all appropriate crontabs and services.  Freshens listed
directories and files.  If any directory or file associated with
a role has been freshened, it will also restart associated services.

(You can supply a hostname other than the machine's own; however, the
main reason for doing so is for the Tuttle test suite).

=cut

sub install {
  my ($self, @hostnames) = @_;

  if ($#hostnames < 0) {
    @hostnames = (`hostname -s`, `hostname -f`, `hostname -a`);
    map { chomp } @hostnames;
  }

  # Check validity of all roles, before we do anything.
  # If there are problems, we don't want to break down halfway.

  my $roles = $self->roles_of_hosts (\@hostnames);

  if ($self->is_disabled) {
    $roles = []
  }

  for my $role (@$roles) {
    $self->check_role ($role);
  }

  # To work.  First, set up directories,
  # cron jobs, and services associated with each role.

  my $install_status =
    {
     # Role status map... an element is created for each role
     # as we configure it, to avoid repeating work if a given
     # sub_role is reached along more than one path.

     role_configured => {},

    };

  $self->{install_record} = {};

  for my $ext (@{$self->{extensions}}) {
    $ext->begin_install
  }

  for my $role (@$roles) {
    $self->install_role ($role, $install_status);
  }

  for my $ext (@{$self->{extensions}}) {
    $ext->end_install
  }

  if ($#$roles == 0 && $roles->[0] eq 'wipeout') {

    # We've already checked that there are no other roles
    # when sanity-checking the config itself...

    $self->wipe_dirs;
  }
}

sub install_role {
  my ($self, $role, $install_status) = @_;

  # We may have already been here, if this role is a sub_role of
  # more than one role, for instance.  So, let's not repeat ourselves...

  return if $install_status->{role_configured}{$role};
  $install_status->{role_configured}{$role} = 1;

  # Haven't been here before.  Let's make sure sub_roles *are* taken
  # care of...

  my $role_spec = $self->{roles}{$role};

  for my $sub_role (@{$role_spec->{sub_roles}}) {
    $self->install_role ($sub_role, $install_status);
  }

  # OK.  Get packages and directories in place before anything else.
  # (Crontabs and services presumably depend on this stuff).

  for my $dir_spec (@{$role_spec->{dirs}}) {
    $self->install_dir ($dir_spec);
  }

  # Extension defined stuff...

  for my $ext_obj (@{$self->{extensions}}) {
    my $class = ref $ext_obj;
    my $ext_state = $role_spec->{role_ext_state}{$class};
    $ext_obj->configure_for_role( $ext_state ) if (defined ($ext_state));
  }

}

################################################################
#
# Dir handling...

sub goldpull {
  my ($self) = @_;
  return $self->{install_prefix} . "/usr/local/bin/goldpull";
}

sub install_dir {
  my ($self, $dir_spec) = @_;
  my $dir = $dir_spec->{dir};
  my $pfx = $self->{install_prefix};

  if (!$dir_spec->{is_really_file}) {
    $self->ensure_dir_exists ($dir);
  }

  $self->owner_mode_fixups ($dir_spec, $dir);

  if (defined $dir_spec->{release}) {
    $self->run_command ($self->goldpull, $dir_spec->{release});
    $self->run_command ("/usr/bin/rsync", "--checksum", "--delete", "-a",
			@{$dir_spec->{release_rsync_flags}},
			$pfx . "/gold/" . $dir_spec->{release} . '/',
			$pfx . $dir);
  }


  if ($dir_spec->{setup}) {
    $self->run_command ("/bin/sh", "-c", "cd $pfx$dir;".$dir_spec->{setup});
  }

  for my $file_spec (@{$dir_spec->{files}}) {
    $self->install_file_copy ($file_spec->{src_name}, $file_spec->{dst_name},
			      %{$file_spec->{options}});
  }

  if (defined ($dir_spec->{tree})) {
    my $tree_base = $dir_spec->{tree}{src_name};
    File::Find::find ({ no_chdir => 1,
			wanted => sub {
			  return if $File::Find::name =~ m|/CVS(/.*)?$|;

			  my $sub_file_name = substr ($File::Find::name,
						      length $tree_base);
			  my $dst_name = $dir . '/' . $sub_file_name;
			  if (-d $File::Find::name) {
			    $self->ensure_dir_exists ($dst_name);
			  }
			  elsif (-f $File::Find::name) {
			    $self->install_file_copy
			      ($File::Find::name, $dst_name);
			  }
			  else {
			    die "Don't know what to do with $File::Find::name";
			  }

			  $self->owner_mode_fixups ($dir_spec, $dst_name);
			}
		      }, $tree_base);
  }

  if (defined ($dir_spec->{forcelinks})) {
    for my $linkspec (@{$dir_spec->{forcelinks}}) {
      my $link_from = $linkspec->{from};
      my $link_to   = $linkspec->{to};
      rmtree  $pfx . $dir . '/' . $link_from;
      symlink $link_to, $pfx . $dir . '/' . $link_from;
      if ($@) {
	die "Error planting symlink: $@";
      }
    }
  }
}

sub owner_mode_fixups {
  my ($self, $dir_spec, $file_name) = @_;

  if (defined ($dir_spec->{owner})) {
    $self->do_chown ($file_name, $dir_spec->{owner});
  }

  if (defined ($dir_spec->{mode})) {
    $self->do_chmod ($file_name, $dir_spec->{mode});
  }
}

sub wipe_dirs {
  my ($self) = @_;
  for my $role_spec (values %{$self->{roles}}) {
    for my $dir_spec (@{$role_spec->{dirs}}) {
      $self->wipe_directory ($dir_spec->{dir});
    }
  }
}

sub check_dir_spec {
  my ($self, $role, $dir_spec) = @_;

  for my $file_spec (@{$dir_spec->{files}}) {
    $self->check_file_keywords ($file_spec->{src_name});
  }

  if (defined ($dir_spec->{tree})) {
    if (! -d $dir_spec->{tree}{src_name}) {
      die "For role $role, tree ". $dir_spec->{tree}{src_name} ." not found";
    }

    File::Find::find ({ no_chdir => 1,
			wanted => sub {
			  if (-f $File::Find::name) {
			    $self->check_file_keywords ($File::Find::name)
			  }
			}},
		      $dir_spec->{tree}{src_name});
  }
}

=head2 $config->roles

Return names of all roles in this configuration

=cut

sub roles {
  my ($self) = @_;
  my @roles = keys %{$self->{roles}};
  return wantarray ? @roles : \@roles;
}

=head2 $config->roles_of_hosts (\@hostnames)

Returns names of all roles declared for any of the hosts named in
@hostnames, either directly, or as sub-roles of its directly declared
roles.  If there are multiple names, these will typically be alternate
names for the same host (e.g., both its short and full hostnames, so
that we can name it either way in Roles.conf).

Return value will be either an array or arrayref, depending on
context in the usual manner.

=cut

sub roles_of_hosts {
  my ($self, $hosts) = @_;
  my @roles;

  for my $role (keys %{$self->{roles}}) {
    for my $host (@$hosts) {
      if (grep { $host eq $_ } @{$self->{roles}{$role}{hosts}}) {
	$self->accum_role ($role, \@roles);
      }
    }
  }

  return wantarray? @roles : \@roles;
}

sub accum_role {
  my ($self, $role, $roles) = @_;
  if (! grep { $role eq $_ } @$roles) {
    push @$roles, $role;
    for my $subrole (@{$self->{roles}{$role}{sub_roles}}) {
      $self->accum_role ($subrole, $roles);
    }
  }
}

=head2 $config->hosts_of_role ($role)

Returns a list of all hosts with role $role, as an array or arrayref
as appropriate.  Includes hosts declared to have the role.  Also includes
hosts declared to have some other role with $role declared as a subrole,
directly or indirectly.

=cut

sub hosts_of_role {
  my ($self, $role) = @_;
  my %hosts;
  for my $role ($self->roles_having_subrole ($role)) {
    for my $host (@{$self->{roles}{$role}{hosts}}) {
      $hosts{$host} = 1;
    }
  }
  my @hosts = sort { $a cmp $b } keys %hosts;
  return wantarray ? @hosts : \@hosts;
}

sub roles_having_subrole {
  my ($self, $role) = @_;
  my @all_roles = keys %{$self->{roles}};
  my @wanted_roles = grep { $self->has_as_subrole ($_, $role) } @all_roles;
  return wantarray ? @wanted_roles : \@wanted_roles;
}

sub has_as_subrole {
  my ($self, $role, $possible_subrole) = @_;
  return 1 if ($role eq $possible_subrole);

  return 0 if !defined ($self->{roles}{$role}{sub_roles});

  my @subs = @{$self->{roles}{$role}{sub_roles}};
  return 1 if grep { $_ eq $possible_subrole } @subs;

  for my $known_subrole (@subs) {
    return 1 if $self->has_as_subrole ($known_subrole, $possible_subrole);
  }

  return 0;
}

=head2 $config->dirs_of_role ($rolename)

A Tuttle configuration can specify directories which are to
be managed as part of the configuration process.  The specification
for these directories may include:

*) Releases to be copied in (as created by our release process)

*) Files to be copied in (managed within Gold, e.g. SSL server certs)

*) Initialization commands (e.g., the "make config" business which
   sets up our Apache config files, based on what's in configFile.txt)

This returns a list (array or arrayref as appropriate) of objects
of the form

  { dir => $name,
    reference_name => $tag,
    release => $release_tag,
    files => [ { src_name => $name, dst_name => $name }, ... ],
    setup => "make ... ",
    [owner => "...",]
    [mode => "...",]
    [recursive => "...",]
    [tree => "..."]
  }

Standalone "file" directives in a role result in a phony "dir" spec,
with dir being the filename, $dir_spec->{is_really_file} being set to
one, and there being one file entry (containing the obvious).

=cut

sub dirs_of_role {
  my ($self, $role) = @_;
  return $self->{roles}{$role}{dirs};
}

################################################################
#
# Dealing with the grotty details of interfacing to the rest
# of the system.  Also deals with the differences between running
# live and running in the "no root required" test harness.

sub install_file_copy {
  my ($self, $src, $declared_dest, %flags) = @_;

  my $dest = $self->{install_prefix} . $declared_dest;

  open (IN, "<$src") or die "Couldn't open $src";
  open (OUT, ">$dest") or die "Couldn't open $dest";

  my $conf = $self->{config_name};

  while (<IN>) {
    $_ = $self->substitute_keywords ($_);
    (print OUT) or die "Couldn't write $dest";
  }

  close IN;
  close OUT or die "Couldn't write $dest";

  $self->do_chown ($declared_dest, $flags{owner}) if (defined ($flags{owner}));
  $self->do_chmod ($declared_dest, $flags{mode})  if (defined ($flags{mode}));
}

sub remove_file {
  my ($self, $file) = @_;
  $file = $self->{install_prefix} . $file;
  unlink $file or print STDERR "Error unlinking $file: $! \n";
}

sub ensure_dir_exists {
  my ($self, $dir) = @_;
  if (! -d $dir) {
    mkpath $self->{install_prefix} . $dir;
  }
}

sub wipe_directory {
  my ($self, $dir) = @_;
  rmtree $self->{install_prefix} . $dir;
}

sub do_chown {
  my ($self, $dir, $owner) = @_;
  if ($self->{install_prefix} eq '') {
    $self->run_command ('/bin/chown', $owner, $dir);
  }
  $self->{install_record}{chown}{$dir} = $owner;
}

sub do_chmod {
  my ($self, $dir, $mode) = @_;
  chmod oct($mode), $self->{install_prefix}.$dir;
  $self->{install_record}{chmod}{$dir} = $mode;
}

sub run_command {
  my ($self, @stuff) = @_;

  my $str = join (' ', @stuff);

  my $status = system (@stuff);
  return 1 if $status == 0;
  print STDERR "Command $str failed -- status $status\n";
  return 0;
}

################################################################
#
# Other useful utilities.

sub substitute_keywords {
  my ($self, $string) = @_;
  $string =~ s/\$tuttle:([^\$]*)\$/$self->keyword_value($1)/eg;
  return $string;
}

=head2 $config->keyword_value ($keyword)

Returns the defined value of keyword $keyword.  That is, if the
Roles.conf file contains

   define my_var foo

then $config->keyword_value('my_var') will return 'foo'.  This
is the underlying mechanism for $tuttle:my_var$ substitutions;
thus, my_var can also be the tag of a directory (in which case
the full path will be returned), or 'hosts:foo' (which gives
a list of hosts with role foo --- though in that case, you might
as well call $config->hosts_of_role directly).

=cut

sub keyword_value {
  my ($self, $keyword) = @_;
  if ($keyword =~ /hosts:(.*)$/) {
    my $foo = join (' ', $self->hosts_of_role ($1));
    return $foo
  }
  elsif (!defined $self->{keywords}{$keyword}) {
    die "Undefined keyword $keyword";
  }
  return $self->{keywords}{$keyword};
}

sub check_file_keywords {
  my ($self, $file) = @_;
  open (IN, "<$file") or die "Could not open $file";
  while (<IN>) {
    while (/\$tuttle:([^\$]*)\$/) {
      my ($keyword) = $1;
      eval { $self->keyword_value ($keyword) };
      if ($@) {
	die "In file $file, keyword $keyword not defined"
      }
      s/\$tuttle:([^\$]*)\$//;
    }
  }
  close (IN);
}

sub locate_config_file {
  my ($self, $name) = @_;

  my @path;
  if (defined ($self->{config_search_path})) {
    @path = @{$self->{config_search_path}}
  }
  else {
    push @path, $self->{basename};
  }

  for my $dir (@path) {
    my $fname = $dir . '/'. $name;
    return $fname if -e $fname;
  }

  push @{$self->{config_spec_errors}},
    "Could not locate config file $name on search path";

  return $name;
}

################################################################
#
# Config file sanity-checks

sub check_full {
  my ($self) = @_;
  $self->check_parsetime;

  if ($#{$self->{config_spec_errors}} >= 0) {
    die join "\n", @{$self->{config_spec_errors}};
  }

  for my $role (keys %{$self->{roles}}) {
    $self->check_role ($role);
  }
}

sub check_role {
  my ($self, $role) = @_;
  my $role_spec = $self->{roles}{$role};
  for my $dir (@{$role_spec->{dirs}}) {
    $self->check_dir_spec ($role, $dir);
  }
  for my $ext (@{$self->{extensions}}) {
    my $class = ref $ext;
    my $role_attrs = $role_spec->{role_ext_state}{$class};
    $ext->check_role_config( $role_attrs );
  }
}

sub check_parsetime {
  my ($self) = @_;
  for my $role (keys %{$self->{roles}}) {
    $self->check_role_loops ($role, []);
  }

  if (defined ($self->{roles}{wipeout})) {
    for my $host (@{$self->{roles}{wipeout}{hosts}}) {
      my $host_roles = $self->roles_of_hosts ([$host]);
      if ($#$host_roles > 0) {
	die "Can't wipe host $host, which has other roles assigned";
      }
    }
  }
}

sub check_role_loops {
  my ($self, $role, $seen) = @_;
  if (grep { $role eq $_ } @$seen) {
    my @loop = @$seen;
    shift @loop while $loop[0] ne $role;
    die "Role loop: " . join (" has ", @loop, $role);
  }

  if (exists $self->{roles}{$role}{sub_roles}) {
    for my $sub_role (@{$self->{roles}{$role}{sub_roles}}) {
      $self->check_role_loops ($sub_role, [ @$seen, $role ]);
    }
  }
}

################################################################
#
# Config file parsing

sub parse {
  my ($self, $filename) = @_;
  my $handle = IO::File->new;
  $handle->open ("<$filename") or die "Couldn't open $filename";

  my $parse_state = { file => $filename,
		      handle => $handle,
		      indent_stack => [] };

  $self->with_lines_of_group
    ($parse_state, sub {
       my (@fields) = @_;
       if ($fields[0] eq 'define') {
	 $self->{keywords}{$fields[1]} = join (' ', @fields[2..$#fields]);
       }
       elsif ($fields[0] eq 'role' && $#fields == 1) {
	 $self->parse_role ($fields[1], $parse_state);
       }
       elsif ($fields[0] eq 'config_search_path'
	      || $fields[0] eq 'config_files_from')
       {

	 if ($fields[0] eq 'config_files_from' &&
	     !defined ($self->{config_search_path}))
	 {
	   $self->{config_search_path} = [ $self->{basename} ];
	 }

	 push @{$self->{config_search_path}},
	   map { $self->{basename} . '/' . $_} @fields[1..$#fields];
       }
       elsif ($fields[0] eq 'include' && $#fields == 1) {
	 my ($real_file) = $self->locate_config_file( $fields[1] );
	 $self->parse( $real_file );
       }
       else {
	 $self->syntax_error ($parse_state);
       }
     });

  $self->check_parsetime;
}

sub parse_role {
  my ($self, $role_name, $parse_state) = @_;
  $self->with_lines_of_group
    ($parse_state, sub {
       my ($decl, @decl_args) = @_;
       if ($decl eq 'has') {
	 push @{$self->{roles}{$role_name}{sub_roles}}, @decl_args;
       } elsif ($decl eq 'hosts') {
	 push @{$self->{roles}{$role_name}{hosts}}, @decl_args;
       } elsif ($decl eq 'dir' && $#decl_args >= 1) {
	 $self->{keywords}{$decl_args[0]} = $decl_args[1];
	 push @{$self->{roles}{$role_name}{dirs}},
	   $self->parse_dir ($decl_args[0], $decl_args[1], $parse_state,
			     @decl_args[2..$#decl_args]);
       }
       elsif ($decl eq 'file') {
	 push @{$self->{roles}{$role_name}{dirs}},
	   $self->parse_standalone_file ($parse_state, @decl_args);
       }
       elsif (defined( $ext_decls{$decl} )) {
	 my $ext_cmd = $ext_decls{$decl};
	 my $ext_pkg = $ext_cmd->{ext};
	 my $ext_handler = $ext_cmd->{handler};
	 my ($ext_obj) = grep { ref $_ eq $ext_pkg } @{$self->{extensions}};
	 $self->{roles}{$role_name}{role_ext_state}{$ext_pkg} ||=
	   $ext_pkg->new_role_config;
	 &$ext_handler( $ext_obj,
			$self->{roles}{$role_name}{role_ext_state}{$ext_pkg},
			@decl_args );
       }
       else {
	 $self->syntax_error ($parse_state);
       }
     });
}

sub parse_dir {
  my ($self, $dir_tag, $dir_name, $parse_state, @flags) = @_;
  my $dir_spec = $self->parse_filesys_options ($parse_state, @flags);

  $dir_spec->{dir} = $dir_name;
  $dir_spec->{reference_name} = $dir_tag;

  $self->with_lines_of_group
    ($parse_state, sub {
       my ($decl, @declargs) = @_;
       if ($decl eq 'release') {
	 my ($release, @rsync_flags) = @declargs;
	 if (defined $dir_spec->{release}) {
	   $self->syntax_error ($parse_state, "Second 'release'");
	 }
	 $dir_spec->{release} = $release;
	 $dir_spec->{release_rsync_flags} = \@rsync_flags;
       }
       elsif ($decl eq 'setup') {
	 if (defined $dir_spec->{setup}) {
	   $self->syntax_error ($parse_state, "Second 'setup'");
	 }
	 $dir_spec->{setup} = join (' ', @declargs);
       }
       elsif ($decl eq 'file') {
	 push @{$dir_spec->{files}},
	   $self->parse_file_spec ($parse_state, $dir_name, @declargs);
       }
       elsif ($decl eq 'tree') {
	 if (defined ($dir_spec->{tree})) {
	   $self->syntax_error ($parse_state, "Second 'tree'");
	 }
	 $dir_spec->{tree} =
	   $self->parse_file_spec ($parse_state, $dir_name, @declargs);
       }
       elsif ($decl eq 'forcelink') {
	 my ($link_from, $link_to) = @declargs;
	 push @{$dir_spec->{forcelinks}},
	   { from => $link_from, to => $link_to };
       }
       else {
	 $self->syntax_error ($parse_state,
			      "Unknown directory sub-declaration $decl");
       }
     });

  return $dir_spec;
}

sub parse_standalone_file {
  my ($self, $parse_state, @decl_args) = @_;
  if ($#decl_args < 1) {
    $self->syntax_error ($parse_state,
			 "Standalone 'file' directive must have dest");
  }
  if (substr ($decl_args[1], 0, 1) ne '/') {
    $self->syntax_error ($parse_state,
			 "Standalone 'file' directive requires ".
			 "absolute path for dest");
  }
  my ($src, $dst, @flags) = @decl_args;
  my $dir_spec = { dir => $dst };
  $src = $self->locate_config_file ($src);
  $dir_spec->{files} = [{ src_name => $src, dst_name => $dst,
			  options =>
			    $self->parse_filesys_options ($parse_state, @flags)
			}];
  $dir_spec->{is_really_file} = 1;
  return $dir_spec;
}

sub parse_filesys_options {
  my ($self, $parse_state, @flags) = @_;

  my $options = {};

  for my $flag (@flags) {
    my $eq_posn = index ($flag, '=');
    if ($eq_posn < 0) {
      $self->syntax_error ($parse_state, "Bad option '$flag'");
    }
    my $flag_name = substr ($flag, 0, $eq_posn);
    my $flag_val = substr ($flag, $eq_posn + 1);
    if ($flag_name ne 'owner' && $flag_name ne 'mode') {
      $self->syntax_error ($parse_state,"Unknown option '$flag_name'");
    }
    $options->{$flag_name} = $flag_val;
  }

  return $options;
}

sub parse_file_spec {
  my ($self, $parse_state, $dir_name, @declargs) = @_;
  if ($#declargs < 0) {
    $self->syntax_error ($parse_state);
  }
  my ($src, $dst, @flags) = @declargs;
  if (!defined ($dst)) { $dst = $src }
  $src = $self->locate_config_file ($src);
  $dst = $dir_name . "/" . $dst;
  return { src_name => $src, dst_name => $dst,
	   options => $self->parse_filesys_options ($parse_state, @flags)
	 };
}

sub with_lines_of_group {
  my ($self, $parse_state, $handler) = @_;
  $self->begin_group ($parse_state);

  while (1) {
    my (@fields) = $self->parsed_line ($parse_state);
    last if ($fields[0] eq 'END');
    &$handler (@fields);
  }
}

sub parsed_line {
  my ($self, $parse_state) = @_;
  my $handle = $parse_state->{handle};
  my $candidate_line;

  if (defined ($parse_state->{deferred_line})) {
    $candidate_line = $parse_state->{deferred_line};
    delete $parse_state->{deferred_line};
  }
  else {
    while (!defined ($candidate_line) && !$handle->eof) {
      my $input_line = $handle->getline;
      chomp $input_line;

      # Ban tabs in indentation-specific files.

      if ($input_line =~ /\t/) {
	die "Tab found in Tuttle config";
      }

      # Strip comments and whitespace.  Ignore blank lines;
      # the amount of indentation present on them is irrelevant.

      $input_line =~ s/#.*//;
      next if ($input_line =~ /^\s*$/);
      $candidate_line = $input_line;
    }

    $candidate_line = 'END' if (!defined ($candidate_line) && $handle->eof);
  }

  $candidate_line =~ /^ */;
  my $indentation = $&;
  my $plain_line = $';

  # End group and defer line if it is outdented... else strip indentation
  # and return that.

  my $indent_stack = $parse_state->{indent_stack};
  my $top_indent = $indent_stack->[$#$indent_stack];
  my $this_indent = length ($indentation);

  if (!defined ($top_indent) || $this_indent > $top_indent) {
    $parse_state->{line_for_errors} = $plain_line;
    $parse_state->{this_line_indent} = $this_indent;
    $plain_line =~ s/\$\$/$self->{config_name}/eg;
    return map { $self->substitute_keywords ($_) } 
             split /\s+/, $plain_line;
  }

  pop @$indent_stack;
  $parse_state->{deferred_line} = $candidate_line;
  return 'END';
}

sub syntax_error {
  my ($self, $parse_state, $complaint) = @_;
  $complaint ||= 'Bad syntax';
  die $complaint . " on line " . $parse_state->{handle}->input_line_number .
    " of " . $parse_state->{file} . ": '" .
      $parse_state->{line_for_errors} . "'";
}

sub begin_group {
  my ($self, $parse_state) = @_;
  push @{$parse_state->{indent_stack}}, $parse_state->{this_line_indent};
}

1;
