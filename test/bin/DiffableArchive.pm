#! /usr/bin/perl -w

#    Tuttle --- Tiny Utility Toolkit for Tweaking Large Environments
#    Copyright (C) 2007-8  Smartleaf, Inc.
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

package DiffableArchive;

use File::Path;
use IO::File;
use Digest::MD5;

use strict;

sub create {
  my ($arch_locn, $dir) = @_;
  my ($output) = new IO::File;
  $output->open(">$arch_locn") or die "Couldn't open $arch_locn";
  &freeze_dry_dir ($output, $dir, '.');
  $output->close;
}

sub freeze_dry_dir {
  my ($output, $full_path, $rel_path) = @_;

  opendir (DIR, $full_path) or die "Couldn't read $full_path";
  my @entries = readdir DIR;
  closedir DIR;

  @entries = sort (grep { $_ ne 'gold' && $_ ne '.' && $_ ne '..' &&
                          $_ ne 'apt-get' && $_ ne 'lock'
			} @entries);

  for my $entry (@entries) {
    my $entry_full_path = "${full_path}/${entry}";
    my $entry_rel_path  = "${rel_path}/${entry}";
    my ($dev, $ino, $mode) = lstat $entry_full_path;
    my ($modestr) = sprintf "%o", ($mode & 0777);

    if (-d $entry_full_path) {
      print $output "==== $entry_rel_path d$modestr\n";
      &freeze_dry_dir ($output, $entry_full_path, $entry_rel_path);
    }
    elsif (-l $entry_full_path) {
      my $target = readlink $entry_full_path;
      print $output "==== $entry_rel_path l$target\n";
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

sub reconstitute_archive {
  my ($archive, $sandbox) = @_;

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

1;
