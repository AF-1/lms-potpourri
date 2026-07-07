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

my $prefs = preferences('plugin.potpourri');
my $log = logger('plugin.potpourri');

use base 'Exporter';
our %EXPORT_TAGS = (
	all => [qw(assignReleaseTypes trim_leadtail trim_all)],
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
