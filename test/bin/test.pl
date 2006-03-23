#! /usr/bin/perl -w

use FindBin;
use lib "$FindBin::Bin/../..";
use Tuttle::Config;
use Data::Dumper;
use File::Path;
use IO::File;
use Digest::MD5;
use strict;

my $testdata_dir = "$FindBin::Bin/../testdata/";
my $sandbox = "$FindBin::Bin/../tmp/sandbox";
my $base = "$sandbox/gold";

# Have to set umask, to make new modes consistent with "freeze-dried"
# regression tests.

umask 022;
&reconstitute_sandbox ($testdata_dir . 'sandbox0.gold');

# A few error tests...

my $c;

eval {
  $c = Tuttle::Config->new ('looptest', "$base/looptest/Tuttle");
};

if (!$@) {
  die "Config loop not detected";
}
else {
  print "Config loop detected -- $@ \n"
}

eval {
  $c = Tuttle::Config->new ('wipeerrtest', "$base/wipeerrtest/Tuttle");
};

if (!$@) {
  die "Wipe conflict not detected";
}
else {
  print "Wipe conflict detected -- $@ \n"
}

eval {
  $c = Tuttle::Config->new ('badkeytest', "$base/badkeytest/Tuttle");
};

if ($@) {
  die "Nonexistent crontab kills at parse time -- $@ \n"
}

eval {
  $c = Tuttle::Config->new ('badkeytest', "$base/badkeytest/Tuttle");
  $c->check_full;
};

if (!$@) {
  die "Failed to detect bad crontab in check_full";
}

eval {
  $c = Tuttle::Config->new ('badkeytest', "$base/badkeytest/Tuttle");
  $c->install ('foo');
};

if (!$@) {
  die '"Successful" install with bad crontab?!';
}

$c = Tuttle::Config->new ('hosts_of_role', 
			  "$base/hosts_of_role_test/Roles.conf");

if ($c->keyword_value ('hosts:d') ne 'a1 a2 b1 b2 d1 d2'
    || $c->keyword_value ('hosts:c') ne 'c1 c2'
    || $c->keyword_value ('hosts:b') ne 'a1 a2 b1 b2'
    || $c->keyword_value ('hosts:a') ne 'a1 a2'
    || $c->substitute_keywords ('$tuttle:hosts:d$') ne 'a1 a2 b1 b2 d1 d2')
{
  die "Can't compute roles of host"
}

# First test installation...

$c = Tuttle::Config->new ('test0', "$base/tuttle/test0/Roles.conf", $sandbox);
print "Install whitney\n";
$c->install ('whitney');
&install_test ('sandbox.whitney');
print "Reinstall as pratt\n";
$c->install ('pratt');
&install_test ('sandbox.pratt');

my $chowns = $c->{install_record}{chown};
my $chmods = $c->{install_record}{chmod};

my $expect_chowns =
{
 '/etc/floppit' => 'kermit_frog',
 '/var/spool/slae-config/test0' => 'advisor',
 '/var/log/slae/test0' => 'advisor',
 '/var/spool/slae-config/test0/slae_pieces.conf' => 'slae_owner'
};

my $expect_chmods =
{
 '/etc/rc.d/init.d/test0.web' => '0755',
 '/etc/floppit' => '467',
 '/etc/rc.d/init.d/test0.slae' => '0755',
 '/var/spool/slae-config/test0' => '0741',
 '/var/log/slae/test0' => '0714',
 '/var/spool/slae-config/test0/slae_pieces.conf' => '0673'
};

for my $k (keys %$expect_chowns) {
  if ($expect_chowns->{$k} ne $c->{install_record}{chown}{$k}) {
    die "Didn't chown $k to $expect_chowns->{$k}";
  }
}

for my $k (keys %$expect_chmods) {
  if ($expect_chmods->{$k} ne $c->{install_record}{chmod}{$k}) {
    die "Didn't chmod $k to $expect_chmods->{$k}";
  }
}

print "Wipe\n";
$c->install ('wiper');
unlink "$sandbox/etc/packages";	# doesn't uninstall in real life
&install_test ('sandbox0');

print "Install pratt\n";
$c->install ('pratt');
system ("ls -ld $sandbox/var/log/slae/test0 $sandbox/var/spool/slae-config/test0");
&install_test ('sandbox.pratt');
print "Reinstall as whitney\n";
$c->install ('whitney');
&install_test ('sandbox.whpratt');
print "Wipe\n";
$c->install ('wiper');
unlink "$sandbox/etc/packages";	# doesn't uninstall in real life
&install_test ('sandbox0');

sub install_test {
  my ($ref_name) = @_;
  my $good_data_locn = $testdata_dir . $ref_name;
  my $arch_locn = "$FindBin::Bin/../tmp/$ref_name";

  &freeze_dry_sandbox($arch_locn);

  if (0 != system ("diff -u $good_data_locn $arch_locn")) {
    die "Unexpected differences with $arch_locn";
  }
}

sub freeze_dry_sandbox {
  my ($arch_locn) = @_;
  my ($output) = new IO::File;
  $output->open(">$arch_locn") or die "Couldn't open $arch_locn";
  &freeze_dry_dir ($output, $sandbox, '.');
  $output->close;
}

sub freeze_dry_dir {
  my ($output, $full_path, $rel_path) = @_;

  opendir (DIR, $full_path) or die "Couldn't read $full_path";
  my @entries = readdir DIR;
  closedir DIR;

  @entries = sort (grep { $_ ne 'gold' && $_ ne '.' && $_ ne '..'
			} @entries);

  for my $entry (@entries) {
    my $entry_full_path = "${full_path}/${entry}";
    my $entry_rel_path  = "${rel_path}/${entry}";
    my ($dev, $ino, $mode) = stat $entry_full_path;
    my ($modestr) = sprintf "%o", ($mode & 0777);

    if (-d $entry_full_path) {
      print $output "==== $entry_rel_path d$modestr\n";
      &freeze_dry_dir ($output, $entry_full_path, $entry_rel_path);
    }
    else {
      # Presume ordinary file.
      my ($chksum) = Digest::MD5->new;
      my ($in) = new IO::File $entry_full_path, "r";
      $chksum->addfile ($in);
      $chksum = $chksum->b64digest;
      $in->close;
      print $output "==== $entry_rel_path $modestr $chksum\n";
      $in = new IO::File $entry_full_path, "r";
      print $output $in->getlines;
      $in->close;
    }
  }
}

sub reconstitute_sandbox {
  my ($archive) = @_;

  rmtree $sandbox;
  mkdir $sandbox or die "Couldn't create $sandbox";

  open (IN, "<$archive") or die "Couldn't read $archive";
  my ($current_output) = undef;

  while (<IN>) {
    if (! /^==== /) {
      print $current_output $_;
    }
    else {
      # Have a new header... current entry is done
      if ($current_output) {
	$current_output->close;
	$current_output = undef;
      }

      if ($_ =~ /^==== ([^ ]+) d([0-7]+)/) {
	# directory entry
	mkdir "$sandbox/$1", oct($2) or die "Couldn't create $sandbox/$1";
      }
      elsif ($_ =~ /^==== ([^ ]+) ([0-7]+) (\S+)/) {
	my $file = "$sandbox/$1";
	$current_output = new IO::File $file, "w";
	chmod oct($2), $file;
	if (!$current_output) {
	  die "Couldn't create $file";
	}
      }
      else {
	die "Garbled header $_";
      }
    }
  }
}
