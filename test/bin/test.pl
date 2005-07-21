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

# First test installation...

$c = Tuttle::Config->new ('test0', "$base/tuttle/test0/Roles.conf", $sandbox);
print "Install whitney\n";
$c->install ('whitney');
&install_test ('sandbox.whitney');
print "Reinstall as pratt\n";
$c->install ('pratt');
&install_test ('sandbox.pratt');
print "Wipe\n";
$c->install ('wiper');
&install_test ('sandbox0');

print "Install pratt\n";
$c->install ('pratt');
&install_test ('sandbox.pratt');
print "Reinstall as whitney\n";
$c->install ('whitney');
&install_test ('sandbox.whpratt');
print "Wipe\n";
$c->install ('wiper');
&install_test ('sandbox0');

sub install_test {
  my ($ref_name) = @_;
  my $dir_name = "$FindBin::Bin/../$ref_name";
  if (0 != system ("diff -qr --exclude=CVS $dir_name $sandbox")) {
    die "Unexpected differences with $dir_name";
  }
}

