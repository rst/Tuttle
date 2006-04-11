#! /usr/bin/perl -w

# Written 2005 by Robert S. Thau

package Tuttle::Config;

require Exporter;

use IO::File;
use File::Path;
use File::Basename;
use File::Spec;
use File::Find;
use strict;

=head1 NAME

  Tuttle::Config -- Tiny Utility Toolkit for Tweaking Large Environments

=head1 SYNOPSIS

  Typically used on the command line:

    perl /gold/tuttle/doit

  which is a trivial wrapper around this:

    use lib '/gold/tuttle';
    use Tuttle::Config;

    chdir '/gold/tuttle';
    for my $dir (grep { $_ ne 'Tuttle' } <*>)
      Tuttle::Config->new ($dir, "$dir/Roles.conf")->install;

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

  # Reasons we can't use this config, even if we could parse it...

  $self->{config_spec_errors} = [];

  $self->parse ($filename);
  return $self;
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

     # Pre-installed services, which we may want to delete...

     unclaimed_services => $self->collect_services,

     # Pre-installed crontabs, which we may want to delete...

     unclaimed_crontabs => $self->collect_crontabs

    };

  $self->{install_record} = {};

  for my $role (@$roles) {
    $self->install_role ($role, $install_status);
  }

  # Now, wrapup.

  for my $crontab (keys %{$install_status->{unclaimed_crontabs}}) {
    $self->remove_crontab ($crontab);
  }

  for my $service (keys %{$install_status->{unclaimed_services}}) {
    $self->remove_service ($service);
  }

  for my $service (keys %{$self->collect_services}) {
    $self->restart_service ($service);
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

  for my $package (@{$role_spec->{packages}}) {
    $self->install_package ($package)
  }

  for my $dir_spec (@{$role_spec->{dirs}}) {
    $self->install_dir ($dir_spec);
  }

  # Now crontabs and services...

  for my $crontab (@{$role_spec->{crontabs}}) {
    $self->install_crontab ($crontab);
    delete $install_status->{unclaimed_crontabs}{$crontab};
  }

  for my $service (@{$role_spec->{services}}) {
    $self->install_service ($service);
    delete $install_status->{unclaimed_services}{$service};
  }
}

################################################################
#
# Crontab handling...

sub crontab_prefix {
  my ($self) = @_;
  return "/etc/cron.d/" . $self->{config_name} . "-";
}

sub crontab_name {
  my ($self, $token) = @_;
  my $pfx = $self->crontab_prefix;
  return $pfx . $token;
}

sub crontab_source_file {
  my ($self, $token) = @_;
  return $self->locate_config_file ('cron.' . $token);
}

sub collect_crontabs {
  my ($self) = @_;
  my $pfx = $self->{install_prefix} . $self->crontab_prefix;
  my @files = <${pfx}*>;
  return { map { substr ($_, length $pfx) => 1 } @files };
}

sub install_crontab {
  my ($self, $token) = @_;

  $self->install_file_copy ($self->crontab_source_file ($token),
			    $self->crontab_name ($token));
}

sub remove_crontab {
  my ($self, $token) = @_;
  $self->remove_file ($self->crontab_name ($token));
}

sub check_crontab_spec {
  my ($self, $role, $token) = @_;
  $self->check_file_keywords ($self->crontab_source_file ($token));
}

################################################################
#
# Service handling...
# Really die on chkconfig failures?  What else to do?

sub collect_services {
  my ($self) = @_;
  opendir (DIR, $self->{install_prefix} . $self->service_file_dir);
  my @services;
  my $pfx = $self->{config_name} . '.';
  for my $service (readdir DIR) {
    if ($pfx eq substr ($service, 0, length $pfx)) {
      push @services, substr ($service, length $pfx);
    }
  }
  closedir DIR;
  return { map { $_ => 1 } @services };
}

sub service_name {
  my ($self, $token) = @_;
  return $self->{config_name} . "." . $token;
}

sub service_file_location {
  my ($self, $token) = @_;
  return $self->service_file_dir . '/' . $self->service_name($token);
}

sub service_file_command {
  # For testing purposes... sigh...
  my ($self, $token) = @_;
  return $self->{install_prefix} . $self->service_file_location ($token);
}

sub service_source_file {
  my ($self, $token) = @_;
  return $self->locate_config_file ('service.' . $token);
}

sub install_service {
  my ($self, $token) = @_;
  print "Install service $token\n";
  $self->install_file_copy ($self->service_source_file ($token),
			    $self->service_file_location ($token),
			    mode => '0755');
  $self->create_service_links ($self->service_name ($token));
}

sub remove_service {
  my ($self, $token) = @_;
  print "Remove service $token\n";
  $self->run_command ($self->service_file_command ($token), "stop");
  $self->remove_service_links ($self->service_name ($token));
  $self->remove_file ($self->service_file_location ($token));
}

sub restart_service {
  my ($self, $token) = @_;
  $self->run_command ($self->service_file_command ($token), "restart");
}

sub check_service_spec {
  my ($self, $role, $token) = @_;
  $self->check_file_keywords ($self->service_source_file ($token));
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

=head2 $config->crontabs_of_role ($rolename)

Returns names of all crontabs relevant to the role named $rolename.
The general rule is that crontab 'foo_jobs' has its master copy in
'/gold/$config_name/cron-foo_jobs', and is installed in
'/etc/cron.d/cron-foo_jobs-$config_name', with $tuttle:foo$ keywords
replaced by the value of keyword foo.  (Keyword 'id' is assigned the
config_name; each "dir foo /bar/zot" creates a keyword foo whose value
is '/bar/zot', and "define key value" at top level does the obvious
thing).

=cut

sub crontabs_of_role {
  my ($self, $role) = @_;
  return $self->{roles}{$role}{crontabs};
}

=head2 $config->services_of_role ($rolename)

Returns names of all services relevant to role $rolename, in
any of its roles.  A service, in concrete terms, is an "init"
file which is to be installed in /etc/rc.d, and enabled at
boot time.

The control file for service 'foo' has its master copy in
'/gold/$config_name/foo.init', and it will be copied into
'/etc/rc.d/foo-$config_name', with appropriate symlinks installed as
by "chkconfig ... on".  Keyword substitution is done as for crontabs.

=cut

sub services_of_role {
  my ($self, $role) = @_;
  return $self->{roles}{$role}{services};
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

=head2 $config->packages_of_role($rolename)

Returns the list of packages that will be installed or freshened
nightly on all hosts with this role.

=cut

sub packages_of_role {
  my ($self, $role) = @_;
  return $self->{roles}{$role}{packages};
}

################################################################
#
# Dealing with the grotty details of interfacing to the rest
# of the system.  Also deals with the differences between running
# live and running in the "no root required" test harness.

sub install_package {
  my ($self, $package) = @_;
  my $installer = $self->{install_prefix} . '/usr/bin/apt-get';
  $self->run_command ($installer, 'install', $package);
}

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

# Services require particularly special treatment...

sub service_file_dir {
  my ($self) = @_;
  for my $candidate (qw(/etc/rc.d/init.d /etc/init.d /etc/rc.d)) {
    if (-d $self->{install_prefix} . $candidate) {
      return $candidate;
    }
  }

  die "Could not find service (init.d file) directory!"
}

sub chkconfig {
  my ($self) = @_;
  return $self->{install_prefix} . '/sbin/chkconfig';
}

sub create_service_links {
  my ($self, $service_name) = @_;
  my $chkconfig  = $self->{install_prefix} . '/sbin/chkconfig';
  my $rcd_update = $self->{install_prefix} . '/usr/sbin/update-rc.d';
  if (-x $chkconfig) {
    $self->run_command ($chkconfig, $service_name, "on");
  }
  elsif (-x $rcd_update) {
    $self->run_command ($rcd_update, $service_name, "defaults");
  }
  else {
    print STDERR "Unable to create links for $service_name; could not find service link editor\n";
  }
}

sub remove_service_links {
  my ($self, $service_name) = @_;
  my $chkconfig  = $self->{install_prefix} . '/sbin/chkconfig';
  my $rcd_update = $self->{install_prefix} . '/usr/sbin/update-rc.d';
  if (-x $chkconfig) {
    $self->run_command ($chkconfig, $service_name, "off");
  }
  elsif (-x $rcd_update) {
    $self->run_command ($rcd_update, "-f", $service_name, "remove");
  }
  else {
    print STDERR "Unable to remove links for $service_name; could not find service link editor\n";
  }
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
  for my $crontab (@{$role_spec->{crontabs}}) {
    $self->check_crontab_spec ($role, $crontab);
  }
  for my $service (@{$role_spec->{services}}) {
    $self->check_service_spec ($role, $service);
  }
  for my $dir (@{$role_spec->{dirs}}) {
    $self->check_dir_spec ($role, $dir);
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
       } elsif ($decl eq 'service') {
	 push @{$self->{roles}{$role_name}{services}}, @decl_args;
       } elsif ($decl eq 'crontab') {
	 push @{$self->{roles}{$role_name}{crontabs}}, @decl_args;
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
       elsif ($decl eq 'package') {
	 push @{$self->{roles}{$role_name}{packages}}, @decl_args
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
