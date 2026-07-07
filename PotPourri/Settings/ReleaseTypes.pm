#
# PotPourri
# (c) 2022 AF
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::PotPourri::Settings::ReleaseTypes;

use strict;
use warnings;
use utf8;

use base qw(Plugins::PotPourri::Settings::BaseSettings);
use Slim::Utils::Prefs;
use Plugins::PotPourri::Common ':all';

my $prefs = preferences('plugin.potpourri');

sub new {
	my ($class, $plugin) = @_;
	$class->SUPER::new($plugin);
}

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_POTPOURRI_SETTINGS_RELEASETYPES');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/PotPourri/settings/releasetypes.html');
}

sub currentPage {
	return name();
}

sub pages {
	my %page = (
		'name' => name(),
		'page' => page(),
	);
	my @pages = (\%page);
	return \@pages;
}

sub prefs {
	return ($prefs, qw(postscan_rltypes));
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	my $result = undef;
	my $maxNoFields = 20;
	if ($paramRef->{'saveSettings'}) {
		my @rltypematrix;

		for (my $n = 0; $n <= $maxNoFields; $n++) {
			my $albumTitleSearchString = trim_leadtail($paramRef->{"pref_albumtitlesearchstring_$n"} // '');
			my $releaseType = $paramRef->{"pref_releasetype_$n"};
			if (length($albumTitleSearchString) > 0) {
				push(@rltypematrix, {'albumtitlesearchstring' => $albumTitleSearchString, 'releasetype' => $releaseType});
			}
		}
		$prefs->set('rltypematrix', \@rltypematrix);
		$paramRef->{'rltypematrix'} = \@rltypematrix;
	}
	if ($paramRef->{'rlmanualadjust'}) {
		$paramRef->{'saveSettings'} = 1;
		assignReleaseTypes();
	}

	# push to settings page
	$paramRef->{'rltypematrix'} = [];
	my $rltypematrix = $prefs->get('rltypematrix');

	foreach my $thisrlType (@{$rltypematrix}) {
		if ($thisrlType->{'albumtitlesearchstring'}) {
			push(@{$paramRef->{'rltypematrix'}}, $thisrlType);
		}
	}

	# add empty field
	if ((scalar @{$rltypematrix} + 1) < $maxNoFields) {
		push(@{$paramRef->{'rltypematrix'}}, {'albumtitlesearchstring' => '', 'releasetype' => ''});
	}

	$result = $class->SUPER::handler($client, $paramRef);
	return $result;
}

1;
