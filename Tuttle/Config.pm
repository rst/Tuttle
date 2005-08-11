#! /usr/bin/perl -w

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
  $self->{config_search_path} = [ $self->{basename} ];

  $self->parse ($filename);
  return $self;
}

=head2 $config->install ([$hostname])

Install the configuration for host $hostname (default `hostname`).
Installs all appropriate crontabs and services.  Freshens listed
directories and files.  If any directory or file associated with
a role has been freshened, it will also restart associated services.

(You can supply a hostname other than the machine's own; however, the
main reason for doing so is for the Tuttle test suite.

=cut

sub install {
  my ($self, $hostname) = @_;

  if (!defined ($hostname)) {
    $hostname = `hostname`;
    chomp $hostname;
  }

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

  # To work.  First, set up directories,
  # cron jobs, and services associated with each role.

  my $roles = $self->roles_of_host ($hostname);

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

  # OK.  Get directories in place before anything else.
  # (Crontabs and services presumably depend on this stuff).

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

sub chkconfig {
  my ($self) = @_;
  return $self->{install_prefix} . '/sbin/chkconfig';
}

sub collect_services {
  my ($self) = @_;
  my $chkconfig = $self->chkconfig;
  open (CONF, "$chkconfig |");
  my @services;
  my $pfx = $self->{config_name} . '.';
  while (<CONF>) {
    chomp;
    my ($service) = split;
    if ($pfx eq substr ($service, 0, length $pfx)) {
      push @services, substr ($service, length $pfx);
    }
  }
  close CONF;
  return { map { $_ => 1 } @services };
}

sub service_name {
  my ($self, $token) = @_;
  return $self->{config_name} . "." . $token;
}

sub service_file_location {
  my ($self, $token) = @_;
  return "/etc/rc.d/init.d/" . $self->service_name($token);
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
			    sub { chmod 0755, $_[0] } );
  $self->run_command ($self->chkconfig, $self->service_name ($token), "on");
}

sub remove_service {
  my ($self, $token) = @_;
  print "Remove service $token\n";
  $self->run_command ($self->service_file_command ($token), "stop");
  $self->run_command ($self->chkconfig, $self->service_name ($token), "off");
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
			$pfx . "/gold/" . $dir_spec->{release} . '/',
			$pfx . $dir);

    if ($dir_spec->{setup}) {
      $self->run_command ("/bin/sh", "-c", "cd $pfx$dir;".$dir_spec->{setup});
    }
  }

  for my $file_spec (@{$dir_spec->{files}}) {
    $self->install_file_copy ($file_spec->{src_name}, $file_spec->{dst_name});
  }

  if (defined ($dir_spec->{tree})) {
    my $tree_base = $dir_spec->{tree}{src_name};
    File::Find::find ({ no_chdir => 1,
			wanted => sub {
			  my $sub_file_name = substr ($File::Find::name,
						      length $tree_base);
			  my $dst_name = $dir . '/' . $sub_file_name;
			  if (-d $File::Find::name) {
			    $self->ensure_dir_exists ($dst_name);
			  }
			  elsif (-f $File::Find::name) {
			    $self->install_file_copy ($File::Find::name,
						      $dst_name);
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

=head2 $config->roles_of_host ($hostname)

Returns names of all roles declared for host $hostname, either
directly, or as sub-roles of its directly declared roles.
Return value will be either an array or arrayref, depending
on context in the usual manner.

=cut

sub roles_of_host {
  my ($self, $host) = @_;
  my @roles;

  for my $role (keys %{$self->{roles}}) {
    if (grep { $host eq $_ } @{$self->{roles}{$role}{hosts}}) {
      $self->accum_role ($role, \@roles);
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

=head2 $config->crontabs_of_host ($hostname)

Returns names of all crontabs relevant to host $hostname, in
any of its roles.  The general rule is that crontab 'foo_jobs'
has its master copy in '/gold/$config_name/cron-foo_jobs', and
is installed in '/etc/cron.d/cron-foo_jobs-$config_name',
with $tuttle:foo$ keywords replaced by the value of keyword
foo.  (Keyword 'id' is assigned the config_name; each 
"dir foo /bar/zot" creates a keyword foo whose value is '/bar/zot',
and "define key value" at top level does the obvious thing).

=cut

sub crontabs_of_host {
  my ($self, $host) = @_;
  return $self->items_of_host ($host, 'crontabs', wantarray);
}

=head2 $config->services_of_host ($hostname)

Returns names of all services relevant to host $hostname, in
any of its roles.  A service, in concrete terms, is an "init"
file which is to be installed in /etc/rc.d, and enabled at
boot time.

The control file for service 'foo' has its master copy in
'/gold/$config_name/foo.init', and it will be copied into
'/etc/rc.d/foo-$config_name', with appropriate symlinks installed as
by "chkconfig ... on".  Keyword substitution is done as for crontabs.

=cut

sub services_of_host {
  my ($self, $host) = @_;
  return $self->items_of_host ($host, 'services', wantarray);
}

=head2 $config->dirs_of_host

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
    release => $tag,
    files => [ { src_name => $name, dst_name => $name }, ... ],
    setup => "make ... ",
    [owner => "..."]
    [mode => "..."]
    [recursive => "..."]
  }

Standalone "file" directives in a role result in a phony "dir" spec,
with dir being the filename, $dir_spec->{is_really_file} being set to
one, and there being one file entry (containing the obvious).

=cut

sub dirs_of_host {
  my ($self, $host) = @_;
  return $self->items_of_host ($host, 'dirs', wantarray);
}

################################################################
#
# Internal utility routines

sub items_of_host {
  my ($self, $host, $item_type, $wantarray) = @_;
  my @items;
  for my $role ($self->roles_of_host ($host)) {
    if (exists $self->{roles}{$role}{$item_type}) {
      push @items, @{$self->{roles}{$role}{$item_type}};
    }
  }
  return $wantarray? @items: \@items;
}

sub install_file_copy {
  my ($self, $src, $dest, $handler) = @_;

  $dest = $self->{install_prefix} . $dest;

  open (IN, "<$src") or die "Couldn't open $src";
  open (OUT, ">$dest") or die "Couldn't open $dest";

  my $conf = $self->{config_name};

  while (<IN>) {
    $_ = $self->substitute_keywords ($_);
    (print OUT) or die "Couldn't write $dest";
  }

  close IN;
  close OUT or die "Couldn't write $dest";

  if (defined ($handler)) { &$handler ($dest); }
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
  if ($self->{install_prefix}) {
    print "Chown $dir to $owner\n";
  }
  else {
    $self->run_command ('/bin/chown', $owner, $dir);
  }
}

sub do_chmod {
  my ($self, $dir, $mode) = @_;
  print "Chmod $dir to $mode\n";
  chmod oct($mode), $self->{install_prefix}.$dir;
}

sub run_command {
  my ($self, @stuff) = @_;

  my $str = join (' ', @stuff);

  my $status = system (@stuff);
  return 1 if $status == 0;
  print STDERR "Command $str failed -- status $status\n";
  return 0;
}

sub substitute_keywords {
  my ($self, $string) = @_;
  $string =~ s/\$tuttle:([^\$]*)\$/$self->keyword_value($1)/eg;
  return $string;
}

sub keyword_value {
  my ($self, $keyword) = @_;
  if (!defined $self->{keywords}{$keyword}) {
    die "Undefined keyword $keyword";
  }
  return $self->{keywords}{$keyword};
}

sub check_file_keywords {
  my ($self, $file) = @_;
  open (IN, "<$file");
  while (<IN>) {
    while (/\$tuttle:([^\$]*)\$/) {
      if (!defined ($self->{keywords}{$1})) {
	die "In file $file, keyword $1 not defined"
      }
      s/\$tuttle:([^\$]*)\$//;
    }
  }
  close (IN);
}

sub locate_config_file {
  my ($self, $name) = @_;
  for my $dir (@{$self->{config_search_path}}) {
    my $fname = $dir . '/'. $name;
    return $fname if -e $fname;
  }
  die "Could not locate config file $name on search path"
}

################################################################
#
# Config file sanity-checks

sub check_roles {
  my ($self) = @_;
  for my $role (keys %{$self->{roles}}) {
    $self->check_role ($role, []);
  }

  if (defined ($self->{roles}{wipeout})) {
    for my $host (@{$self->{roles}{wipeout}{hosts}}) {
      my $host_roles = $self->roles_of_host ($host);
      if ($#$host_roles > 0) {
	die "Can't wipe host $host, which has other roles assigned";
      }
    }
  }
}

sub check_role {
  my ($self, $role) = @_;
  $self->check_role_loops ($role, []);
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
       elsif ($fields[0] eq 'config_files_from') {
	 push @{$self->{config_search_path}},
	   map { $self->{basename} . '/' . $_} @fields[1..$#fields];
       }
       else {
	 $self->syntax_error ($parse_state);
       }
     });

  $self->check_roles;
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
       } elsif ($decl eq 'dir') {
	 $self->{keywords}{$decl_args[0]} = $decl_args[1];
	 push @{$self->{roles}{$role_name}{dirs}},
	   $self->parse_dir ($decl_args[1], $parse_state,
			     @decl_args[2..$#decl_args]);
       }
       elsif ($decl eq 'file') {
	 push @{$self->{roles}{$role_name}{dirs}},
	   $self->parse_standalone_file ($parse_state, @decl_args);
       }
       else {
	 $self->syntax_error ($parse_state);
       }
     });
}

sub parse_dir {
  my ($self, $dir_name, $parse_state, @flags) = @_;
  my $dir_spec = $self->parse_dir_flags ($parse_state, $dir_name, @flags);

  $self->with_lines_of_group
    ($parse_state, sub {
       my ($decl, @declargs) = @_;
       if ($decl eq 'release') {
	 if ($#declargs != 0) {
	   $self->syntax_error ($parse_state)
	 }
	 elsif (defined $dir_spec->{release}) {
	   $self->syntax_error ($parse_state, "Second 'release'");
	 }
	 $dir_spec->{release} = $declargs[0];
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
  my $dir_spec = $self->parse_dir_flags ($parse_state, $dst, @flags);
  $src = $self->locate_config_file ($src);
  $dir_spec->{files} = [{ src_name => $src, dst_name => $dst }];
  $dir_spec->{is_really_file} = 1;
  return $dir_spec;
}

sub parse_dir_flags {
  my ($self, $parse_state, $dir_name, @flags) = @_;
  my $dir_spec = { dir => $dir_name };

  for my $flag (@flags) {
    my $eq_posn = index ($flag, '=');
    if ($eq_posn < 0) {
      $self->syntax_error ($parse_state, "Bad directory flag '$flag'");
    }
    my $flag_name = substr ($flag, 0, $eq_posn);
    my $flag_val = substr ($flag, $eq_posn + 1);
    if ($flag_name ne 'owner' && $flag_name ne 'mode') {
      $self->syntax_error ($parse_state,"Unknown directory flag '$flag_name'");
    }
    $dir_spec->{$flag_name} = $flag_val;
  }

  return $dir_spec;
}

sub parse_file_spec {
  my ($self, $parse_state, $dir_name, @declargs) = @_;
  if ($#declargs < 0 || $#declargs > 1) {
    $self->syntax_error ($parse_state);
  }
  my ($src, $dst) = @declargs;
  if (!defined ($dst)) { $dst = $src }
  $src = $self->locate_config_file ($src);
  $dst = $dir_name . "/" . $dst;
  return { src_name => $src, dst_name => $dst };
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
