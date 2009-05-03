#! /usr/bin/perl -w

#    Tuttle --- Tiny Utility Toolkit for Tweaking Large Environments
#    Copyright (C) 2007  Smartleaf, Inc.
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

use FindBin;
use lib "$FindBin::Bin";
use lib "$FindBin::Bin/../..";
use Tuttle::Config;
use Data::Dumper;
use Digest::MD5;
use DiffableArchive;
use File::Path;
use strict;

my $testdata_dir = "$FindBin::Bin/../testdata/";
my $sandbox = "$FindBin::Bin/../tmp/sandbox";
my $base = "$sandbox/gold";

# Have to set umask, to make new modes consistent with "freeze-dried"
# regression tests.

print "$FindBin::Bin/../tmp\n";
mkpath( "$FindBin::Bin/../tmp", 1 );

umask 022;
&DiffableArchive::reconstitute_archive ($testdata_dir . 'sandbox0.gold',
					$sandbox);

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

eval {
  $c = Tuttle::Config->new('bad_dir_test', "$base/bad_dir_test/Roles.conf")
};

if (!$@) {
  die "'Dir' syntax error not detected";
}
else {
  print "'Dir' syntax error detected --- $@\n"
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
 '/etc/floppit' => '647',
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
print "Disable; check status\n";
$c->disable;
$c->install ('pratt');
&install_test ('sandbox.pratt_disabled');
print "Enable; verify undone\n";
$c->enable;
$c->install ('pratt');
&install_test ('sandbox.pratt');
print "Reinstall as whitney\n";
$c->install ('whitney');
&install_test ('sandbox.whpratt');
print "Wipe\n";
$c->install ('wiper');
unlink "$sandbox/etc/packages";	# doesn't uninstall in real life
&install_test ('sandbox0');

################################################################
# So much for sandbox0.  On to sandbox 1...

&DiffableArchive::reconstitute_archive ($testdata_dir . 'sandbox1.gold',
					$sandbox);

eval {
  $c = Tuttle::Config->new('forcelinktest', "$base/forcelink_test/Roles.conf",
			      $sandbox);
};

if ($@) {
  die "forcelink fails at parse time... -- $@ \n"
}

$c->install( 'somehost' );
&install_test( 'sandbox1.forcelink' );

print "All tests pass.\n";

sub install_test {
  my ($ref_name) = @_;
  my $good_data_locn = $testdata_dir . $ref_name;
  my $arch_locn = "$FindBin::Bin/../tmp/$ref_name";

  &DiffableArchive::create($arch_locn, $sandbox);

  if (0 != system ("diff -u $good_data_locn $arch_locn")) {
    die "Unexpected differences with $arch_locn";
  }
}

