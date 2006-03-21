#! /usr/bin/perl -w

use FindBin;
use lib "$FindBin::Bin/../..";
use Tuttle::Config;
use Data::Dumper;
use File::Path;

$sandbox_src = "$FindBin::Bin/../sandbox0/";
$sandbox = "$FindBin::Bin/../tmp/sandbox";
$base = "$sandbox/gold";

rmtree $sandbox;
system ("/usr/bin/rsync", "--checksum", "--delete", "-a",
	$sandbox_src, $sandbox);

# A few error tests...

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
  my $dir_name = "$FindBin::Bin/../$ref_name";
  if (0 != system ("diff -qr --exclude=CVS --exclude=gold $dir_name $sandbox")) {
    die "Unexpected differences with $dir_name";
  }
  if (-d "$sandbox/var/spool/invoices/CVS" || 
      -d "$sandbox/var/spool/invoices/client1/CVS")
  {
    die "'tree' directive copying CVS files"
  }
}

