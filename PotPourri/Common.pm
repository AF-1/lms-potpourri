#
# PotPourri
# (c) 2022 AF
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::PotPourri::Common;

use strict;
use warnings;
use utf8;

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Time::HiRes qw(time);
use File::Copy qw(copy move);
use File::Basename qw(dirname);
use File::Temp ();
use Cwd ();

my $prefs = preferences('plugin.potpourri');
my $log = logger('plugin.potpourri');

use base 'Exporter';
our %EXPORT_TAGS = (
	all => [qw(assignReleaseTypes isPathAllowed isPathWritable transferFile trim_leadtail trim_all)],
);
our @EXPORT_OK = ( @{ $EXPORT_TAGS{all} } );

sub assignReleaseTypes {
	main::DEBUGLOG && $log->is_debug && $log->debug('Start assigning release types.');
	my $started = time();
	my $rltypematrix = $prefs->get('rltypematrix');
	main::DEBUGLOG && $log->is_debug && $log->debug('rltypematrix = '.Data::Dump::dump($rltypematrix));

	if (scalar @{$rltypematrix} > 0) {
		my $dbh = Slim::Schema->dbh;
		my $sth = $dbh->prepare("update albums set release_type = ? where title LIKE ?");

		foreach my $thisrltype (@{$rltypematrix}) {
			my $albumtitlesearchstring = '%'.$thisrltype->{'albumtitlesearchstring'}.'%';
			eval {
				$sth->bind_param(1, $thisrltype->{'releasetype'});
				$sth->bind_param(2, $albumtitlesearchstring);
				$sth->execute();
			};
			if ($@) {
				$log->error("Database error: $@");
			}
		}
		$sth->finish();
	}
	main::INFOLOG && $log->is_info && $log->info('Finished assigning release types after '.(time() - $started).' secs.');
}

sub isPathAllowed {
	my ($path, $allowedDirs) = @_;
	return 0 unless defined $path && length $path && -d $path;
	my $resolvedPath = Cwd::realpath($path);
	return 0 unless defined $resolvedPath;

	foreach my $baseDir (@{$allowedDirs}) {
		my $resolvedBase = Cwd::realpath($baseDir);
		next unless defined $resolvedBase;
		if ($resolvedPath eq $resolvedBase || index($resolvedPath, $resolvedBase.'/') == 0) {
			return 1;
		}
	}
	return 0;
}

sub isPathWritable {
	my $dir = shift;
	return 0 unless $dir;

	# don't rely on the -w permission bit alone, it can be unreliable with ACLs;
	# instead actually attempt to create a temp file (see LMS commit 50e5b72)
	while ($dir && !-d $dir) {
		my $parentDir = dirname($dir);
		last if $parentDir eq $dir;
		$dir = $parentDir;
	}
	return 0 unless $dir && -d $dir;

	my $testFile;
	eval {
		(undef, $testFile) = File::Temp::tempfile('potpourriwritetestXXXX', DIR => $dir, UNLINK => 1);
	};
	if ($testFile && -f $testFile) {
		unlink $testFile;
		return 1;
	}
	return 0;
}

sub transferFile {
	my ($source, $dest, $mode) = @_;
	return (0, 'sourcenotreadable') unless -r $source;
	return (0, 'sourceisdir') if -d $source;
	return (0, 'targetexists') if -e $dest;

	my $ok = ($mode && $mode eq 'move') ? File::Copy::move($source, $dest) : File::Copy::copy($source, $dest);
	return (0, "$!") unless $ok;
	return (1, undef);
}

sub trim_leadtail {
	my ($str) = @_;
	$str =~ s{^\s+}{};
	$str =~ s{\s+$}{};
	return $str;
}

sub trim_all {
	my ($str) = @_;
	$str =~ s/ //g;
	return $str;
}

1;
