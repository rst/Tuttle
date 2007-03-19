#! /usr/bin/perl -w

# Written 2005-2007 by Robert S. Thau

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

# This is mainly a source of overview perldoc...

=head1 NAME

Tuttle -- Tiny Utility Toolkit for Tweaking Large Environments

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

=head1 INTRODUCTION

Tuttle is a tool designed to solve some configuration management
issues we faced at Smartleaf: we have collections of machines ---
our production cluster, and several test environments --- which look
broadly similar, but differ in detail.

The preceding sentence is phrased rather carefully: the
I<environments> are broadly similar, but differ in detail.  They
may, for instance, run the same services on different ports, send
alerts to different email addresses, have web servers configured to
contact different database schemata, and so forth.  However, the
machines I<within> the environments can differ quite significantly.
Each environment may have one or more web/compute servers, one or
more "batch" servers whose configuration differs in small but
crucial ways from the web servers, a machine that collects and
coordinates financial datafeeds of various kinds, and perhaps a
standby for the datafeed machine.  The datafeed managers aren't
necessarily configured much at all like the compute servers --- but
they must know the identities of, and be able to communicate with
them, and share relevant configuration (databases, port numbers,
etc.) in common.

To add to the complexity, we need to be able to quickly create new
environments.  We may also need to quickly add a machine to an
environment (say, as a backup for a failing compute server), ideally
installing RPMs and other software needed for its new roles.  And we
may just as quickly want to shut down services associated with a
particular environment (when the main compute server has come back),
while preserving log files, etc.

In short, we need a tool which is focused on managing I<environments>
as a whole, rather than on managing the machines that comprise them.
So, from our point of view, an environment does not consist, first
and foremost, of a collection of machines.  Rather, it is a collection
of I<processes>, started out of crontabs or C</etc/init.d> services,
which run on various machines.  The machines are hosts for various
processes that comprise the environments.

From this description, you might ask whether we could ever want the
same machine running processes which play a role in more than one
environment.  We do --- for example, our internal development setup
has two test rigs ("alpha" and "gamma"), running on the same servers,
without interfering with each other.

=head1 CONFIGURATION BASICS

As indicated above, Tuttle is a tool for configuring computational
I<environments>, which consist of one or more processes (permanent
services or scheduled cron jobs), on each of one or more machines,
along with whatever support infrastructure is needed to run those
processes, in terms of config files, libraries, binaries, log
directories, and so forth.

=head2 Roles, config files, and crontabs

The way we describe these configurations is by declaring that each
machine has one (or more) I<roles>.  When a machine is configured
for an environment (automatically, by running C<tuttle-master-job>
out of cron, or manually, typically by running the C<configure-for>
script), files associated with each of the machine's roles,
including C</etc/cron.d> and C</etc/init.d> files, are installed,
and C<init.d> services are started.

So, for example, a sample environment might declare:

  role combined_web_server
    hosts web5 web6

  role combined_batch_server
    hosts comp5 comp6

  role datagen
    hosts data2

to specify assignments of hosts to roles.  The roles themselves
are specified a bit later on, perhaps like so:

  role combined_batch_server
    has combined_server
    crontab batch
    crontab batch-upload

  role combined_web_server
    has combined_server invoice_web_server
    crontab web

  role combined_server
    service web

Note that there can be a hierarchy of roles; any machine that has the
C<combined_batch_server> role is automatically a C<combined_server> as
well, and inherits all the crontabs, etc.  You may notice that
there's nothing in this sample which installs the software which
the cron jobs, etc., actually run.  And, indeed, the full declaration
of the C<combined_server> role actually has quite a bit more:

  role combined_server
    service web
    package xercesc
    dir web_dir /opt/web/$tuttle:id$ owner=$tuttle:webuser$ mode=0755
      release ...
      file ...

specifying software to be installed on all machines with the role.
But it's easiest to explain Tuttle's operation by focusing on the
crontabs first, so we'll pretend that the rest of the stuff isn't
there.  Yet.

At any rate, these declarations go in a file named, by convention,
C<sample/Roles.conf>, in a directory whose name, C<sample> in this
case, is I<the name of the environment>.  Other files in this
directory are typically templates for configuration files of various
sorts, which might include, say, C<sample/cron.batch>,
C<sample/cron.web>, and C<sample/cron.batch-upload>.  Typically, this
is all maintained on a master, or "gold" server, and automatically
copied to the machines being configured, which we'll call "slaves".

So, what does this all do?

Well, let's say that Tuttle is configuring, say, the machine named
C<web5> for our sample environment.  That's a C<combined-web-server>,
so the relevant declarations include:

    crontab web
    service web

but I<not>

    crontab batch
    crontab batch-upload

So, when Tuttle is configuring C<web5> for our environment, it will
look for a file named C<cron.web> in the same directory as the relevant
C<Roles.conf> (or on a defined search path), perform
template substitution (a matter I'll come to shortly), and install the
result on C<web5> as C</etc/cron.d/sample-web>.

Note that the name of the installed version of this crontab fragment
includes the name of the environment.  This provides unambiguous
information about where this strange thing came from.  And that, in
turn, can be useful in a subsequent Tuttle run, as follows:

Tuttle imposes the convention that, if C<env> is the name of the
environment, then all C<env-foo> crontab fragments --- that is, any
file whose name matches the pattern C</etc/cron.d/env-*> --- is
assumed to be associated with one of that machine's roles in the
C<env> environment.  In fact, Tuttle believes this strongly enough
that if it finds such a file, and it is I<not> associated with any of
the machine's declared environments, it will remove the file.

This behavior of removing unexpected crontabs may seem a bit drastic,
but there is a payoff: if roles or crontabs are removed from the
master configuration, they go away on the individual slave servers as
well.  Tuttle thus provides an "undo"/"deconfigure" capability.

Let's say, for instance, that we decide that the C<cron.web> file was
a mistake --- it just wasn't necessary.  Well, we can remove the

    crontab web

declaration from the master C<Roles.conf> file.  It still exists on
each of the slaves, as C</etc/cron.d/sample-web>.  But, the next time
each slave is configured, Tuttle will determine that it is no longer
associated with any of the machine's currently configured roles, and
get rid of it, neatly solving a problem which can be rather more
awkward with some other tools.

Now, let's suppose we just want to reassign the machine named C<web5>
to another use.  We might wish to make it, say, a batch server.  That
means changing the relevant role declarations to:

  role combined_web_server
    hosts web6

  role combined_batch_server
    hosts web5 comp5 comp6

In this case, the declarations relevant to C<web5>'s new current roles
would be:

    service web
    crontab batch
    crontab batch-upload

but I<not>

    crontab web

Next time C<web5> is updated, the crontabs associated with the new
role (C<batch>, C<batch-upload>) will be installed --- and the one
associated with the old role will just go away, with no need for
explicit action.

We might even wish to take C<web5> out of the C<sample> environment
altogether, removing all relevant cron jobs (and, as I'll discuss
below, removing and shutting down all services).  This sort of thing
can be a real pain in the neck with some other tools, to the point
that people just do a reinstall on the bare metal --- perhaps
destroying C<sample> log files, etc., in the process (which may not be
the best thing in the world if C<sample> is a customer-facing
environment).

But with Tuttle, that's easy.  You just take the machine, C<web5> in
this instance, out of all the C<role> declarations in
C<sample/Roles.conf>, and configure C<web5> for the C<sample>
environment.  Tuttle will then do what it always does --- install
C</etc/cron.d/sample-*> files which are associated with C<web5>'s
declared roles in the C<sample> environment, and remove all the
others.  Since C<web5> no longer I<has> any roles in the C<sample>
environment, it has no relevant crontabs either.  Any C<cron.d> files
associated with the C<sample> environment are no longer relevant, and
they all get removed.

=head2 Services

A service, in typical Unix parlance, is a permanently running process,
generally started by C<init> during the bootstrap process, and shut
down when the machine shuts down.  The most usual arrangement, these
days, is for the startup/shutdown scripts to be located in some
subdirectory of C</etc/init.d>.  Tuttle is capable of installing
services on SuSE, and Debian-based systems (and probably RedHat as
well), using the C<chkconfig> or C<update-rc.d> utilities as
appropriate to make sure that the services it installs are shut down
and restarted by C<init> as appropriate.

The basics are the more or less similar to those for crontabs:  The

    service web

declaration causes Tuttle to look for a file, C<service.web>, in the
same directory as the relevant C<Roles.conf> file (or on a declared
search path), and install it in C</etc/init.d>, or some appropriate
subdirectory, under the name, say, C</etc/init.d/sample.web> (or
perhaps C</etc/init.d/rc.d/sample.web>).  And, just as for crontabs,
files matching the pattern C</etc/init.d/sample.*> which are not
relevant to any of the machine's declared roles get removed.

However, in addition to just installing (or removing) the files,
Tuttle takes some additional actions when installing or removing
services:

=over

=item *

When installing a service, Tuttle will invoke the relevant system
utility (C<chkconfig>, C<update-rc.d>) to make sure that C<init>
will restart the service on reboot, and shut it down on shutdown,
Additionally, it will attempt to start the service itself, once
the machine is otherwise fully configured (i.e., all software
associated with its roles has been installed).

=item *

When removing a service, Tuttle will first attempt to use the script,
as it finds it, to shut down any associated process.  And it will use
C<chkconfig>, etc., to attempt to undo the actions it took upon
installation, so C<init> will no longer attempt to restart a service
that is no longer relevant or fully configured.

=back

The intent here is the same as for crontab handling.  If a service
disappears from a role in the master configuration, it is shut down
and removed on the slaves.  And if a role is deassigned to a machine,
the services associated with that role are likewise shut down and
put away.

=head2 Multiple environments and template substitution

As I indicated above, Tuttle was originally written to handle a
situation in which we have multiple environments which are similar,
but differ in detail.  So, each will have, say, a C<cron.batch>,
to periodically run jobs from a queue, but that job will have to,
say, mail its notifications to an environment-specific address.

The way we handle this, using Tuttle, is to have the C<cron.batch>
file specifying batch-runner cron job look something like this:

  MAILTO=$tuttle:notification_email$

  #  Run batch analysis job

  01 * * * * $tuttle:analysis_user$ perl $tuttle:web_dir$/util/analysis_queue_process.pl

Each environment's C<Roles.conf> file then typically specifies:

  define notification_email some_email_address@smartleaf.com
  define analysis_user freduser
  ...

  config_search_path . ../sl_config_common

The C<config_search_path> specifies that Tuttle should look for cron
files, service templates, etc., in both the directory containing
C<Roles.conf> itself, and its sibling directory named
C<sl_config_common>.  That directory is, of course, where the common
crontabs and services live.  The C<define>s are then used to replace
tokens of the form C<$tuttle:I<whatever>>.

In addition to tokens created with an explicit C<define>, there are a
few "default" C<$tuttle:foo$> tokens which are supplied by default,
and may be useful:

=over

=item $tuttle:id$

This expands to the name of the environment currently being
configured, and may be useful in declaring locations to install
support files, etc., as described below.

=item $tuttle:hosts:ROLE_NAME$

This expands to a space-separated list of all hosts having role
ROLE_NAME in the current environment --- either because they have it
directly, or because they inherit it from some other role.  For
instance, in the sample configuration above,
C<$tuttle:hosts:web_server$> would expand to C<web5 web6>, but
C<$tuttle:hosts:combined_server$> would expand to
C<web5 web6 comp5 comp6>, since all those hosts inherit the base
C<combined_server> role, though none are declared to have it directly.

This may be useful in configuring monitors and the like.

=item $tuttle:DIR_NAME$

Lastly, if Tuttle has been asked to create a directory on all hosts
with a given role, it is given a tag name for that directory, which
has the effect of a C<define>.  I will discuss that in the section
on installing support files, below.

=back

=head2 Installing software packages

Tuttle can use C<apt-get> to install software required for a role,
if packaged as C<deb>s, or C<RPM>s.  Declare:

  role foo
    package bar

and Tuttle will invoke

  apt-get install bar

whenever configuring a machine that has role C<foo>.

Unfortunately, there is no magic deinstallation magic here; once a
package is installed, it sticks, and deconfiguring the role won't
cause Tuttle to remove it.  This hasn't been a burden for us, because
we use this feature for packages such as libraries which don't install
crontabs or services on their own; when a role is deconfigured, the
support software is still there, but it's no longer doing anything.

=head2 Installing directories and files

Tuttle can create directories on slave machines, which
are needed to support their roles.  The syntax is as follows:

  role foo
    dir tag_name /path/including-$tuttle:id$/maybe owner=... mode=...
      file master_template_path slave/install/path
      file master_template_path
      tree master_template_path
      setup shell command text

All sub-declarations (C<file>, C<tree>, C<setup>) are optional, of course.
Note also that the destination path (specifying where the directory is
created on the slave machines), and the owner and the mode can include
C<$tuttle:foo$> tokens.

Also, each C<master_template_path> refers to a file (or, in the case
of C<tree>, a directory) which Tuttle will try to find by looking on
the C<config_search_path> which it also uses for C<cron> and
C<service> files.  The effects will be explained by example.  Given

  define webuser server_monkey

  role combined_server
    dir web_dir /web/$tuttle:id$ owner=$tuttle:webuser$ mode=0755
      file top_level_conf
      file other_conf confdir/other
      tree web_setup_tree
      setup $tuttle:web_dir$/bin/setup.sh -setuparg $tuttle:setupfoo$

in C<sample/Roles.conf>, Tuttle will do the following:

=over

=item *

The directory will be created, with the given user and mode, if it
doesn't already exist.  After tokens are substituted, that means that
a directory C</web/sample> will be created, owned by the
user C<server_monkey>.  Even if the directory already exists, it will
be C<chown>ed and C<chmod>ed to have the specified user and file mode.

=item *

Also, for the benefit of crontab templates, etc., Tuttle will
internally do the equivalent of

  define web_dir /web/sample

so that they may refer to $tuttle:web_dir$, etc.

=item *

Tuttle will look for a file named C<top_level_conf> on its
C<config_search_path>.  Having found it, it will perform template
substitution, as for a C<cron> file or C<service>, and will install
the result in C</web/sample/confdir/other> on each slave with
this role.

=item *

Tuttle will look for a file named C<other_conf> on its
C<config_search_path>.  Having found it, it will perform template
substitution, and will install the result in
C</web/sample/config_search_path> on each slave with this role.

=item *

Tuttle will look along its config search path for a directory named
C<web_setup_tree>, either in C</gold/tuttle/sample>, or in other
directories on its C<config_search_path>.  I<All> files in that
directory will be treated as templates, and I<each> will be installed
in C</web/sample>, with the same relative path.  That is,
C<web_setup_tree/foo> will be installed (after template substitution)
into C</web/sample/foo>, and C<web_setup_tree/bar> will be installed
into C</web/sample/bar>.

Subdirectories will be created with the same owner and mode as
for their parent.  Note that it is possible to do:

      role foo
        dir web_dir /web/$tuttle:id$ owner=web_user mode=0755
        dir web_upload_dir $tuttle:web_dir$/uploads owner=conf_user mode=0740
          tree web_conf

It is also possible to do:

      role foo
        dir web_dir /web/$tuttle:id$ owner=web_user mode=0755
          tree web_stuff_$tuttle:id$

to pull in, say, a set of templates or cobrand config which is
specific to a given installation.

(Smartleaf actually uses a variant on this to install entire
production code snapshots; it is awkward to use more standard code
packaging utilities, e.g. RPM for this, because we want to have, e.g.,
code for multiple test environments installed on a single development
box.  While RPM has limited support for relocatable RPMs, it really
can't cope with different versions of the same RPM being
simultaneously installed at different locations.  The best way we're
aware of to try to make that work would be to have multiple RPM
databases, one per environment --- but if you do that, you lose most
the benefits of using RPM, because each database doesn't know about
packages installed with the others, and can't track dependencies or
conflicts.  The scheme we have isn't wonderfully elegant, but it's
simple and it works).

=item *

Lastly, if a C<setup> subdeclaration is given, the text will be
subject to substitution for C<$tuttle:foo$> variables, and then
the command will be run.  Typically the command run is something
that was installed by, e.g., a C<tree> subdirective.

=back

Sometimes, you just want to install a single file.  In this case,
you can do:

  role foo
    file master_template_path /slave/install/path owner=... mode= ...

=head2 Deinstalling directories and files --- if you must!

Tuttle will I<not> ordinarily remove directories or files created in a
prior run, on the general assumption that you might want to leave them
around.  To cite one common case, you might be taking a server out of
the production web server pool.  But if it's a production machine, you
almost certainly I<don't> want to wipe out the logs --- not, at least,
unless you've made arrangements to copy them elsewhere first.

If you absolutely want to remove all trace of a given environment from
a machine, Tuttle can be told to do that, but you have to be sure.
The conditions are as follows.  If a machine, say,
C<dying_server.smartleaf.com>, is:

=over

=item *

Assigned to the special role C<to_be_wiped>, like so:

      role to_be_wiped
        hosts dying_server.smartleaf.com

=item *

Assigned to I<no other role> within the environment

=back

then all directories and files named in C<dir> and C<file>
declarations for I<any> of the environment's roles will be
removed, if they exist.

This is considered a milder alternative to a full OS reinstall,
which is why it's deliberately hard (though perhaps not hard
enough!) to invoke by accident.

=head2 Invoking Tuttle

As indicated above, Tuttle is ordinarily installed as part of a "gold
server" setup, a la C<infrastructures.org>, in which a central "gold"
machine serves as a repository for master configuration files, and
slave machines periodically fetch copies of the master files, and
update themselves accordingly.

No Tuttle facility described I<yet> in this document requires any
particular form or schedule of communication with the master.  The
same is true for the most common means of invoking Tuttle.  You're
expected to synch up the slave's copy of the Tuttle config files with
the master, by whatever local means are appropriate, and then invoke
either the C<configure-for> script, to reconfigure the machine for its
roles in one environment, or C<tuttle-master-job>, which reconfigures
the machine for its roles in I<all> known environments.

However, it's a little hard to discuss these things in the pure
abstract, so I'll describe Smartleaf's local conventions for
installing Tuttle here.

Tuttle was designed to use a pre-existing local configuration fetch
script at Smartleaf, with roughly the following interface: It assumes
that there is a script installed on each slave machine,

  /usr/local/bin/goldpull

which has the effect that

  goldpull foo

will fetch the entire 'foo' subdirectory tree from a repository
on the master server (e.g., by C<rsync>), and place a copy on the
slave machine in the directory

  /gold/foo

In particular, it expects that

  goldpull tuttle

will fetch a directory with the layout:

  tuttle/
    bin/
      configure-for
      tuttle-master-job
      ...
    Tuttle/          ---- perl code, including the Tuttle::Config module
                          that does most of the work
    env1/
      Roles.conf
      env1configa
      env1configb
    env2/
      Roles.conf
      env2configa
      env2configc
    common_config/
      cron.foo
      cron.bar
      ...

(A simple-minded sample C<goldpull> script is in
C<bin/goldpull.sample> of the distribution; the real one is somewhat
more paranoid about network outages and the like).

If C<goldpull tuttle> does have this effect, then the sequence

  slave$ sudo goldpull tuttle
  slave$ sudo /gold/tuttle/bin/install

will create an C</etc/cron.d> cron fragment that does an automatic
nightly update of the local copy of C</gold/tuttle>, and then runs
C<tuttle-master-job> to reconfigure the machine for all known
environments.

The sequence

  slave$ sudo goldpull tuttle
  slave$ sudo /gold/tuttle/bin/tuttle-master-job

will force a one-time, immediate update.

Lastly, the sequence

  slave$ sudo goldpull tuttle
  slave$ sudo /gold/tuttle/bin/configure-for [environmentname]

will reconfigure the machine for its roles in one environment only.
(That's handy if the same machine is being used to host multiple
test environments; we have a lot of that).

In each case, when configuring a machine for an environment, Tuttle
first reads through the relevant C<Roles.conf> file to make sure that
there are no syntax errors, that it can locate all templates that the
C<Roles.conf> refers to, and that all C<$tuttle:foo$> references in
the templates (and C<Roles.conf> itself) are defined.  If there are
any problems, Tuttle won't do a thing with that environment on this
slave (though it may be able to configure the machine for other
environments, so long as they're OK).

The C<bin/tuttle-check-all> script just performs the checks, and
may be invoked on the master as well as the slaves to do at least
a basic sanity check after editing the config files.  However, it
checks only the Tuttle token references; for syntax errors in the
C</etc/init.d> shell code (or whatever) that surrounds them, you
are, regrettably, on your own.

=cut


