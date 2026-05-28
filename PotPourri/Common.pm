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
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Log;
use Time::HiRes qw(time);

my $prefs = preferences('plugin.potpourri');
my $serverPrefs = preferences('server');
my $log = Slim::Utils::Log::logger('plugin.potpourri');

use base 'Exporter';
our %EXPORT_TAGS = (
	all => [qw(assignReleaseTypes commit rollback)],
);
our @EXPORT_OK = ( @{ $EXPORT_TAGS{all} } );

sub assignReleaseTypes {
	main::DEBUGLOG && $log->is_debug && $log->debug('Start assigning release types.');
	my $started = time();
	my $rltypematrix = $prefs->get('rltypematrix');
	main::DEBUGLOG && $log->is_debug && $log->debug('rltypematrix = '.Data::Dump::dump($rltypematrix));

	if (scalar @{$rltypematrix} > 0) {
		my $dbh = Slim::Schema->dbh;
		my $sql = "update albums set release_type = ? where title LIKE ?";

		foreach my $thisrltype (@{$rltypematrix}) {
			my $albumtitlesearchstring = '%%'.$thisrltype->{'albumtitlesearchstring'}.'%%';
			my $sth = $dbh->prepare($sql);
			eval {
				$sth->bind_param(1, $thisrltype->{'releasetype'});
				$sth->bind_param(2, $albumtitlesearchstring);
				$sth->execute();
				commit($dbh);
			};
			if ($@) {
				$log->error("Database error: $DBI::errstr");
				eval {
					rollback($dbh);
				};
			}
			$sth->finish();
		}
	}
	main::INFOLOG && $log->is_info && $log->info('Finished assigning release types after '.(time() - $started).' secs.');
}

sub commit {
	my $dbh = shift;
	if (!$dbh->{'AutoCommit'}) {
		$dbh->commit();
	}
}

sub rollback {
	my $dbh = shift;
	if (!$dbh->{'AutoCommit'}) {
		$dbh->rollback();
	}
}

1;
