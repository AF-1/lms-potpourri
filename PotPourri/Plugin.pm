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

package Plugins::PotPourri::Plugin;

use strict;
use warnings;
use utf8;

use base qw(Slim::Plugin::Base);

use Scalar::Util qw(blessed);
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Prefs;
use Slim::Utils::Text;
use Slim::Utils::Unicode;
use List::Util qw(shuffle);
use Slim::Schema;
use Data::Dumper;

use Plugins::PotPourri::Settings;

my $log = Slim::Utils::Log->addLogCategory({
	'category' => 'plugin.potpourri',
	'defaultLevel' => 'WARN',
	'description' => 'PLUGIN_POTPOURRI',
});
my $serverPrefs = preferences('server');
my $prefs = preferences('plugin.potpourri');


sub initPlugin {
	my $class = shift;
	$class->SUPER::initPlugin(@_);
	initPrefs();
	if (main::WEBUI) {
		require Plugins::PotPourri::Settings;
		require Plugins::PotPourri::PlayerSettings;
		Plugins::PotPourri::Settings->new($class);
		Plugins::PotPourri::PlayerSettings->new();
	}
	Slim::Web::Pages->addPageFunction('playlistactions', \&changePLtrackOrder_web);

	Slim::Menu::PlaylistInfo->registerInfoProvider(potpourri_plrandomize => (
		func => sub {
			return objectInfoHandler(@_, 1);
		},
	));
	Slim::Menu::PlaylistInfo->registerInfoProvider(potpourri_plinvert => (
		after => 'potpourri_plrandomize',
		func => sub {
			return objectInfoHandler(@_, 2);
		},
	));

	Slim::Control::Request::addDispatch(['potpourri', 'changeplaylisttrackorder', '_action', '_playlistid'], [0, 0, 1, \&changePLtrackOrder_jive]);

	Slim::Control::Request::subscribe(\&setStartVolumeLevel,[['power']]);
	Slim::Control::Request::subscribe(\&initPLtoplevellink,[['rescan'],['done']]);
}

sub initPrefs {
	$prefs->init({
		toplevelplaylistname => 'none',
		powerofftime => '15:08',
	});

	$prefs->setValidate({
		validator => sub {
			if (defined $_[1] && $_[1] ne '') {
				return if $_[1] =~ m|[\^{}$@<>"#%?*:/\|\\]|;
				return if $_[1] =~ m|.{61,}|;
			}
			return 1;
		}
	}, 'alterativetoplevelplaylistname');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 0, 'high' => 100}, 'presetVolume');
	$prefs->setValidate({'validator' => \&isTimeOrEmpty}, 'powerofftime');

	$prefs->setChange(sub {
			$log->debug('Change in toplevelPL config detected. Reinitializing top level PL link.');
			initPLtoplevellink();
		}, 'toplevelplaylistname', 'alterativetoplevelplaylistname');
	$prefs->setChange(\&powerOffClientsScheduler, 'enablescheduledclientspoweroff', 'powerofftime');
}

sub postinitPlugin {
	unless (!Slim::Schema::hasLibrary() || Slim::Music::Import->stillScanning) {
		initPLtoplevellink();
	}
	powerOffClientsScheduler();
}

sub powerOffClientsScheduler {
		$log->debug('Killing existing timers for scheduled power-off');
		Slim::Utils::Timers::killOneTimer(undef, \&powerOffClients);
		my $enableScheduledClientsPowerOff = $prefs->get('enablescheduledclientspoweroff');
		if ($enableScheduledClientsPowerOff) {
		my $powerOffTime = $prefs->get('powerofftime');

		if (defined($powerOffTime) && $powerOffTime ne '') {
			my $time = 0;
			$powerOffTime =~ s{
				^(0?[0-9]|1[0-9]|2[0-4]):([0-5][0-9])\s*(P|PM|A|AM)?$
			}{
				if (defined $3) {
					$time = ($1 == 12?0:$1 * 60 * 60) + ($2 * 60) + ($3 =~ /P/?12 * 60 * 60:0);
				} else {
					$time = ($1 * 60 * 60) + ($2 * 60);
				}
			}iegsx;

			my ($sec,$min,$hour,$mday,$mon,$year) = localtime(time);
			my $currenttime = $hour * 60 * 60 + $min * 60;

			if ($currenttime == $powerOffTime) {
				$log->debug('Current time '.parse_duration($currenttime).' = scheduled power-off time '.parse_duration($powerOffTime).'. Powering off all players now');
				powerOffClients();
				return;
			} else {
				my $timeleft = $powerOffTime - $currenttime;
				$timeleft = $timeleft + 24 * 60 * 60 if $timeleft < 0; # it's past powerOffTime -> schedule for same time tomorrow
				$log->debug(parse_duration($timeleft)." until next scheduled power-off at ".parse_duration($powerOffTime));
				Slim::Utils::Timers::setTimer(0, time() + $timeleft, \&powerOffClients);
			}
		}
	}
}

sub powerOffClients {
	$log->debug('Killing existing timers for powerOffClientsScheduler');
	Slim::Utils::Timers::killOneTimer(undef, \&powerOffClientsScheduler);
	$log->info('Powering off all players!!!');
	foreach my $client (Slim::Player::Client::clients()) {
		$client->power(0) if $client->power();
	}
	Slim::Utils::Timers::setTimer(0, time() + 70, \&powerOffClientsScheduler);
}


sub initPLtoplevellink {
	$log->debug('Started initializing playlist toplevel link.');
	# deregister item first
	Slim::Menu::BrowseLibrary->deregisterNode('PTP_HOMEMENU_TOPLEVEL_LINKEDPLAYLIST');

	# link to playlist in home menu
	my $toplevelplaylistname = $prefs->get('toplevelplaylistname') || 'none';
	if ($toplevelplaylistname eq 'none') {
		$prefs->set('alterativetoplevelplaylistname', '');
	}
	my $alterativetoplevelplaylistname = $prefs->get('alterativetoplevelplaylistname') || '';
	$log->debug('toplevelplaylistname = '.$toplevelplaylistname);
	$log->debug('alterativetoplevelplaylistname = '.Dumper($alterativetoplevelplaylistname));
	if ($toplevelplaylistname ne 'none') {
		my $homemenuTLPLname;
		if ($alterativetoplevelplaylistname ne '') {
			$log->debug('alterativetoplevelplaylistname = '.$alterativetoplevelplaylistname);
			$homemenuTLPLname = registerCustomString($alterativetoplevelplaylistname);
		} else {
			$homemenuTLPLname = registerCustomString($toplevelplaylistname);
		}
		$log->debug('name of home menu item for linked playlist = '.$homemenuTLPLname);
		my $toplevelplaylistID = getPlaylistIDforName($toplevelplaylistname);
		$log->debug('toplevelplaylistID = '.$toplevelplaylistID);

		Slim::Menu::BrowseLibrary->registerNode({
			type => 'link',
			name => $homemenuTLPLname,
			params => {'playlist_id' => $toplevelplaylistID},
			feed => \&Slim::Menu::BrowseLibrary::_playlistTracks,
			icon => 'plugins/PotPourri/html/images/browsemenupfoldericon.png',
			jiveIcon => 'plugins/PotPourri/html/images/browsemenupfoldericon.png',
			homeMenuText => $homemenuTLPLname,
			condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
			id => 'PTP_HOMEMENU_TOPLEVEL_LINKEDPLAYLIST',
			weight => 79,
			cache => 0,
		});
	}
	$log->debug('Finished initializing playlist toplevel link.');
}

sub objectInfoHandler {
	my ($client, $url, $obj, $remoteMeta, $tags, $filter, $action) = @_;
	$tags ||= {};

	return undef if !$action;

	my $playlistID= $obj->id;
	my $playlistName = $obj->name;
	my $name = $action == 1 ? $client->string('PLUGIN_POTPOURRI_PL_RANDOMIZE') : $client->string('PLUGIN_POTPOURRI_PL_INVERT');
	my $jive = {};

	if ($tags->{menuMode}) {
		my $actions = {
			go => {
				player => 0,
				cmd => ['potpourri', 'changeplaylisttrackorder', $action, $playlistID],
				nextWindow => 'parent',
			},
		};
		$actions->{play} = $actions->{go};
		$actions->{add} = $actions->{go};
		$actions->{'add-hold'} = $actions->{go};
		$jive->{'actions'} = $actions;

		return {
			type => 'text',
			jive => $jive,
			name => $name,
			favorites => 0,
		};

	} else {
		return {
			type => 'redirect',
			name => $name,
			favorites => 0,
			web => {
				url => 'plugins/PotPourri/playlistactions?playlistid='.$playlistID.'&action='.$action.'&playlistname='.$playlistName
			},
		};
	}
}

sub changePLtrackOrder_jive {
	my $request = shift;
	if (!$request->isCommand([['potpourri'],['changeplaylisttrackorder']])) {
		$log->warn('incorrect command');
		$request->setStatusBadDispatch();
		return;
	}

	my $action = $request->getParam('_action');
	my $playlistID = $request->getParam('_playlistid');
	$log->debug('action = '.$action.' ## playlistid = '.$playlistID);

	changePLtrackOrder($playlistID, $action);
	$request->setStatusDone();
}

sub changePLtrackOrder_web {
	my ($client, $params, $callback, $httpClient, $response) = @_;
	my $playlistID = $params->{'playlistid'};
	my $action = $params->{'action'};
	$log->debug('playlistID = '.$playlistID.' ## action = '.$action);

	my $failed = changePLtrackOrder($playlistID, $action);
	return Slim::Web::HTTP::filltemplatefile('plugins/PotPourri/html/playlistactionsfb.html', $params) unless $failed;
}

sub changePLtrackOrder {
	my ($playlistID, $action) = @_;
	if (!$playlistID || !$action) {
		$log->error('Missing playlist id or action.');
		return 1;
	}

	my $playlist = Slim::Schema->find('Playlist', $playlistID);
	return 1 if !blessed($playlist);

	my @PLtracks = $playlist->tracks;
	return 1 if scalar @PLtracks < 2;

	@PLtracks = shuffle(shuffle(@PLtracks)) if $action == 1;
	@PLtracks = reverse @PLtracks if $action == 2;

	$playlist->setTracks(\@PLtracks);
	$playlist->update;

	if ($playlist->content_type eq 'ssp') {
		$log->debug('Writing playlist to disk.');
		Slim::Formats::Playlists->writeList(\@PLtracks, undef, $playlist->url);
	}

	Slim::Schema->forceCommit;
	Slim::Schema->wipeCaches;
	return 0;
}

sub setStartVolumeLevel {
	my $request = shift;
	my $client = $request->client();
	return unless defined $client;

	my $clientPrefs = $prefs->client($client);
	my $enabledSetStartVolumeLevel = $clientPrefs->get('enabledsetstartvolumelevel');
	return unless $enabledSetStartVolumeLevel;

	my $curVolume = $serverPrefs->client($client)->get('volume');

	if ($client->power()) {
		my $alarm = Slim::Utils::Alarm->getCurrentAlarm($client);
		return if defined $alarm;

		my $volume = $enabledSetStartVolumeLevel == 2 ? $clientPrefs->get('lastVolume') || 18 : $clientPrefs->get('presetVolume');
		if (!$clientPrefs->get('allowRaise')) {
			$log->debug("allowRaise disabled. Current: ".$curVolume." Target: ".$volume);
			return if ($curVolume <= $volume);
		}
		$log->debug("Setting volume for client '".$client->name()."' to ".($enabledSetStartVolumeLevel == 2 ? "last" : "preset")." $volume");
		$client->execute(["mixer", "volume", $volume]);
	} else {
		$prefs->client($client)->set('lastVolume', $curVolume);
		$log->debug("Saving last volume $curVolume for client '".$client->name()."'");
	}
}


sub getPlaylistIDforName {
	my $playlistname = shift;
	my $queryresult = Slim::Control::Request::executeRequest(undef, ['playlists', 0, 1, 'search:'.$playlistname]);
	my $existsPL = $queryresult->getResult('count');
	my $playlistid;
	if ($existsPL > 0) {
		$log->debug("Playlist '".$playlistname."' exists.");
		my $PLloop = $queryresult->getResult('playlists_loop');
		foreach my $playlist (@{$PLloop}) {
			$playlistid = $playlist->{id};
		}
	return $playlistid || '' ;
	} else {
		$log->warn("Couldn't find selected playlist to link to.")
	}
}

sub registerCustomString {
	my $string = shift;
	if (!Slim::Utils::Strings::stringExists($string)) {
		my $token = uc(Slim::Utils::Text::ignoreCase($string, 1));
		$token =~ s/\s/_/g;
		$token = 'PLUGIN_PTP_PLTOPLEVELNAME_' . $token;
		Slim::Utils::Strings::storeExtraStrings([{
			strings => {EN => $string},
			token => $token,
		}]) if !Slim::Utils::Strings::stringExists($token);
		return $token;
	}
	return $string;
}

sub parse_duration {
	use integer;
	sprintf("%02dh:%02dm", $_[0]/3600, $_[0]/60%60);
}

sub isTimeOrEmpty {
	my $name = shift;
	my $arg = shift;
	if (!$arg || $arg eq '') {
		return 1;
	} elsif ($arg =~ m/^([0\s]?[0-9]|1[0-9]|2[0-4]):([0-5][0-9])\s*(P|PM|A|AM)?$/isg) {
		return 1;
	}
	return 0;
}

1;
