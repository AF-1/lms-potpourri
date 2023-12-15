#
# PotPourri
#
# (c) 2022 AF
#
# GPLv3 license
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#

package Plugins::PotPourri::Settings::Export;

use strict;
use warnings;
use utf8;

use base qw(Plugins::PotPourri::Settings::BaseSettings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Utils::Strings;
use Slim::Utils::Strings qw(string cstring);

my $prefs = preferences('plugin.potpourri');
my $log = logger('plugin.potpourri');

my $plugin;

sub new {
	my $class = shift;
	$plugin = shift;
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
	my $callHandler = 1;
	if ($paramRef->{'saveSettings'}) {
		my @exportbasefilepathmatrix;
		my %lmsbasepathDone;

		for (my $n = 0; $n <= 10; $n++) {
			my $lmsbasepath = trim($paramRef->{"pref_lmsbasepath_$n"} // '');
			my $substitutebasepath = trim($paramRef->{"pref_substitutebasepath_$n"} // '');

			if ((length($lmsbasepath) > 0) && !$lmsbasepathDone{$lmsbasepath} && (length($substitutebasepath) > 0)) {
				push(@exportbasefilepathmatrix, {lmsbasepath => $lmsbasepath, substitutebasepath => $substitutebasepath});
				$lmsbasepathDone{$lmsbasepath} = 1;
			}
		}
		$prefs->set('exportbasefilepathmatrix', \@exportbasefilepathmatrix);
		$paramRef->{exportbasefilepathmatrix} = \@exportbasefilepathmatrix;

		$result = $class->SUPER::handler($client, $paramRef);
		$callHandler = 0;
	}
	if ($paramRef->{'export'}) {
		if ($callHandler) {
			$paramRef->{'saveSettings'} = 1;
			$result = $class->SUPER::handler($client, $paramRef);
		}
		Plugins::PotPourri::Plugin::exportPlaylistsToFiles($paramRef->{'pref_exportPLid'});
	} elsif ($callHandler) {
		$result = $class->SUPER::handler($client, $paramRef);
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

sub trim {
	my ($str) = @_;
	$str =~ s{^\s+}{};
	$str =~ s{\s+$}{};
	return $str;
}

1;
