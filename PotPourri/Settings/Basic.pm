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

package Plugins::PotPourri::Settings::Basic;

use strict;
use warnings;
use utf8;

use base qw(Plugins::PotPourri::Settings::BaseSettings);

use Slim::Utils::Prefs;
use Slim::Utils::Log;

my $log = logger('plugin.potpourri');
my $prefs = preferences('plugin.potpourri');

my $plugin;

sub new {
	my $class = shift;
	$plugin = shift;
	$class->SUPER::new($plugin,1);
}

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_POTPOURRI');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/PotPourri/settings/basic.html');
}

sub currentPage {
	return Slim::Utils::Strings::string('PLUGIN_POTPOURRI_SETTINGS_VARIOUS');
}

sub pages {
	my %page = (
		'name' => Slim::Utils::Strings::string('PLUGIN_POTPOURRI_SETTINGS_VARIOUS'),
		'page' => page(),
	);
	my @pages = (\%page);
	return \@pages;
}

sub prefs {
	return ($prefs, qw(toplevelplaylistname enablescheduledclientspoweroff powerofftime appitem displaytrackid));
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	my $result = undef;
	my $callHandler = 1;
	if ($paramRef->{'saveSettings'}) {
		$result = $class->SUPER::handler($client, $paramRef);
		$callHandler = 0;
	}
	if ($paramRef->{'purgedeadtrackspersistent'}) {
		if ($callHandler) {
			$result = $class->SUPER::handler($client, $paramRef);
		}
		Plugins::PotPourri::Plugin::purgeDeadTracksPersistent();
	} elsif ($callHandler) {
		$result = $class->SUPER::handler($client, $paramRef);
	}
	return $result;
}

sub beforeRender {
	my ($class, $paramRef) = @_;
	my $toplevelplaylistname = $prefs->get('toplevelplaylistname') || 'none';
	my @allplaylists = ();
	my $queryresult = Slim::Control::Request::executeRequest(undef, ['playlists', '0', '500']);
	my $playlistcount = $queryresult->getResult('count');

	if ($playlistcount > 0) {
		my $playlistarray = $queryresult->getResult('playlists_loop');
		push @{$playlistarray}, {playlist => 'none', id => 0};
		my @pagePLarray;

		foreach my $thisPL (@{$playlistarray}) {
			my $thisPLname = $thisPL->{'playlist'};
			my $chosen = '';
			$chosen = 'yes' if $thisPLname eq $toplevelplaylistname;
			my $thisPLid = $thisPL->{'id'};
			push @pagePLarray, {playlist => $thisPLname, id => $thisPLid, chosen => $chosen};
		}
		my @sortedarray = sort {$a->{id} <=> $b->{id}} @pagePLarray;

		main::DEBUGLOG && $log->is_debug && $log->debug('sorted playlists = '.Data::Dump::dump(\@sortedarray));
		if ($toplevelplaylistname ne 'none') {
			$paramRef->{homemenuplaylist} = 'linked';
		}
		$paramRef->{playlistcount} = $playlistcount;
		$paramRef->{allplaylists} = \@sortedarray;
	}
}

1;
