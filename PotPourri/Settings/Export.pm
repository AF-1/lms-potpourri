#
# PotPourri
# (c) 2022 AF
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::PotPourri::Settings::Export;

use strict;
use warnings;
use utf8;

use base qw(Plugins::PotPourri::Settings::BaseSettings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Plugins::PotPourri::Common ':all';

my $prefs = preferences('plugin.potpourri');
my $log = logger('plugin.potpourri');

sub new {
	my ($class, $plugin) = @_;
	$class->SUPER::new($plugin);
}

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_POTPOURRI_SETTINGS_EXPORT');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/PotPourri/settings/export.html');
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
	return ($prefs, qw(exportextension exportextensionexceptions));
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	my $result = undef;
	if ($paramRef->{'saveSettings'}) {
		my @exportbasefilepathmatrix;
		my %lmsbasepathDone;

		for (my $n = 0; $n <= 10; $n++) {
			my $lmsbasepath = trim_leadtail($paramRef->{"pref_lmsbasepath_$n"} // '');
			my $substitutebasepath = trim_leadtail($paramRef->{"pref_substitutebasepath_$n"} // '');

			if ((length($lmsbasepath) > 0) && !$lmsbasepathDone{$lmsbasepath} && (length($substitutebasepath) > 0)) {
				push(@exportbasefilepathmatrix, {lmsbasepath => $lmsbasepath, substitutebasepath => $substitutebasepath});
				$lmsbasepathDone{$lmsbasepath} = 1;
			}
		}
		$prefs->set('exportbasefilepathmatrix', \@exportbasefilepathmatrix);
		$paramRef->{exportbasefilepathmatrix} = \@exportbasefilepathmatrix;
	}
	if ($paramRef->{'export'}) {
		$paramRef->{'saveSettings'} = 1;
		Plugins::PotPourri::Plugin::exportPlaylistsToFiles($paramRef->{'pref_exportPLid'});
	}

	# push to settings page
	$paramRef->{exportbasefilepathmatrix} = [];
	my $exportbasefilepathmatrix = $prefs->get('exportbasefilepathmatrix');

	if (scalar @{$exportbasefilepathmatrix} == 0) {
		Plugins::PotPourri::Plugin::initExportBaseFilePathMatrix();
		$exportbasefilepathmatrix = $prefs->get('exportbasefilepathmatrix');
	}

	foreach my $exportbasefilepath (@{$exportbasefilepathmatrix}) {
		if ($exportbasefilepath->{'lmsbasepath'}) {
			push( @{$paramRef->{exportbasefilepathmatrix}}, $exportbasefilepath);
		}
	}

	# add empty field (max = 11)
	if ((scalar @{$exportbasefilepathmatrix} + 1) < 10) {
		push(@{$paramRef->{exportbasefilepathmatrix}}, {lmsbasepath => '', substitutebasepath => ''});
	}

	$result = $class->SUPER::handler($client, $paramRef);
	return $result;
}

sub beforeRender {
	my ($class, $paramRef) = @_;
	my @allplaylists = ();
	my @localPlaylists = ();
	my $queryresult = Slim::Control::Request::executeRequest(undef, ['playlists', '0', '500', 'tags:x']);
	my $playlistarray = $queryresult->getResult("playlists_loop");

	foreach my $thisPlaylist (@{$playlistarray}) {
		push @localPlaylists, $thisPlaylist if $thisPlaylist->{'remote'} == 0;
	}
	my $playlistcount = scalar (@localPlaylists);

	if ($playlistcount > 0) {
		my @sortedarray = sort {$a->{id} <=> $b->{id}} @localPlaylists;
		main::DEBUGLOG && $log->is_debug && $log->debug("sorted playlists = ".Data::Dump::dump(\@sortedarray));
		$paramRef->{playlistcount} = $playlistcount;
		$paramRef->{allplaylists} = \@sortedarray;
	}
}

1;
