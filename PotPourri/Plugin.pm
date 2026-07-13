#
# PotPourri
# (c) 2022 AF
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::PotPourri::Plugin;

use strict;
use warnings;
use utf8;

use base qw(Slim::Plugin::OPMLBased);

use Scalar::Util qw(blessed);
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Prefs;
use Slim::Utils::Text;
use Slim::Utils::Unicode;
use Slim::Control::Request;
use List::Util qw(shuffle);
use Time::HiRes qw(time);
use POSIX qw(strftime);
use Slim::Schema;
use File::Spec::Functions qw(:ALL);
use List::Util qw(max);
use Archive::Zip qw(:ERROR_CODES);
use YAML::XS qw(LoadFile);
use File::Temp qw(tempdir);
use FileHandle;
use Path::Class;
use XML::Parser;
use Digest::MD5 qw(md5_hex);

my $log = Slim::Utils::Log->addLogCategory({
	'category' => 'plugin.potpourri',
	'defaultLevel' => 'ERROR',
	'description' => 'PLUGIN_POTPOURRI',
});
my $serverPrefs = preferences('server');
my $prefs = preferences('plugin.potpourri');
my %sortOptionLabels;
my ($apc_enabled, $material_enabled, $rl_enabled, $originalMixerVolumeCommand);
my ($tpBackupParser, $tpBackupParserNB, $tpRestoreFH, $tpOpened, $tpInTrack, $tpInValue, $tpCurrentKey, $tpRestoreCount, $tpRestoreStarted, $tpRestoreFile, $tpRestoreDateAdded, $tpRestorePlayCountLastPlayed, $tpTotalTrackCount, $tpProcessedTrackCount, $tpRestoreErrors, $bkpZip, $bkpFile, $bkpTempDir, $bkpOutput, $bkpTotalTrackCount, $bkpProcessedTrackCount, $bkpStarted, $bkpErrors);
my @bkpPersistentTracks;
my %tpRestoreItem;

use Plugins::PotPourri::Common ':all';
use Plugins::PotPourri::Importer;


sub initPlugin {
	my $class = shift;

	initPrefs();
	if (main::WEBUI) {
		require Plugins::PotPourri::Settings::Basic;
		require Plugins::PotPourri::Settings::Export;
		require Plugins::PotPourri::Settings::CommentTagInfo;
		require Plugins::PotPourri::PlayerSettings;
		require Plugins::PotPourri::Settings::ReleaseTypes;
		require Plugins::PotPourri::Settings::BackupRestoreSettings;
		Plugins::PotPourri::Settings::Basic->new($class);
		Plugins::PotPourri::Settings::Export->new($class);
		Plugins::PotPourri::Settings::CommentTagInfo->new($class);
		Plugins::PotPourri::PlayerSettings->new($class);
		Plugins::PotPourri::Settings::ReleaseTypes->new($class);
		Plugins::PotPourri::Settings::BackupRestoreSettings->new($class);
	}

	Slim::Menu::PlaylistInfo->registerInfoProvider(potpourri_changeplsortorder => (
		after => 'addplaylist',
		func => sub {
			return playlistSortContextMenu(@_);
		},
	));
	if ($prefs->get('displaytrackid')) {
		Slim::Menu::TrackInfo->registerInfoProvider('zppt_infotrackid' => (
			parent => 'moreinfo', isa => 'bottom',
			func => sub { return getTrackIdForContextMenu(@_); }
		));
	}
	if ($prefs->get('contextmenusimilartracktitlesbysameartist')) {
		Slim::Menu::TrackInfo->registerInfoProvider('ppt_similartracktitlesbysameartist' => (
			before => 'moreinfo',
			func => sub { return _getSimilarTrackTitlesHandler(0, @_); }
		));
	}
	if ($prefs->get('contextmenusimilartracktitles')) {
		Slim::Menu::TrackInfo->registerInfoProvider('ppt_similartracktitles' => (
			after => 'ppt_similartracktitlesbysameartist',
			func => sub { return _getSimilarTrackTitlesHandler(1, @_); }
		));
	}

	Slim::Web::Pages->addPageFunction('playlistsortorderselect', \&changePLtrackOrder_web);
	Slim::Web::Pages->addPageFunction('playlistsortorderoptions.html', \&changePLtrackOrder_web);
	Slim::Web::Pages->addPageFunction('showsimilartracktitleslist.html', \&_getSimilarTrackTitles_web);

	Slim::Control::Request::addDispatch(['potpourri', 'changeplaylisttrackorderoptions', '_playlistid', '_playlistname'], [1, 1, 1, \&changePLtrackOrder_jive_choice]);
	Slim::Control::Request::addDispatch(['potpourri', 'changeplaylisttrackorder', '_playlistid', '_sortoption', '_playlistname'], [1, 0, 1, \&changePLtrackOrder_jive]);
	Slim::Control::Request::addDispatch(['potpourri', 'similartracktitlesbysameartist', '_trackid'], [1, 0, 1, \&_getSimilarTrackTitles_jive]);
	Slim::Control::Request::addDispatch(['potpourri', 'similartracktitles', '_trackid'], [1, 0, 1, \&_getSimilarTrackTitles_jive]);
	Slim::Control::Request::addDispatch(['potpourri', 'actionsmenu'], [0, 1, 1, \&_getActionsMenu]);
	$originalMixerVolumeCommand = Slim::Control::Request::addDispatch(['mixer', 'volume', '_newvalue'],[1, 0, 1, \&_limitVolumeControl]);

	Slim::Control::Request::subscribe(\&setStartVolumeLevel,[['power']]);
	Slim::Control::Request::subscribe(\&initPLtoplevellink,[['rescan'],['done']]);

	initExportBaseFilePathMatrix();

	if ($prefs->get('appitem')) {
		$class->SUPER::initPlugin(
			feed => \&handleFeed,
			tag => 'potpourri',
			is_app => 1,
		);
	} else {
		$class->SUPER::initPlugin(@_);
	}
}

sub postinitPlugin {
	$apc_enabled = Slim::Utils::PluginManager->isEnabled('Plugins::AlternativePlayCount::Plugin');
	main::DEBUGLOG && $log->is_debug && $log->debug('Plugin "Alternative Play Count" is enabled') if $apc_enabled;
	$rl_enabled = Slim::Utils::PluginManager->isEnabled('Plugins::RatingsLight::Plugin');
	main::DEBUGLOG && $log->is_debug && $log->debug('Plugin "Ratings Light" is enabled') if $rl_enabled;
	$material_enabled = Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin');
	main::DEBUGLOG && $log->is_debug && $log->debug('Plugin "Material Skin" is enabled') if $material_enabled;

	unless (!Slim::Schema::hasLibrary() || Slim::Music::Import->stillScanning) {
		initPLtoplevellink();
	}
	_requeuePendingRescanAfterRestart();
	powerOffClientsScheduler();
	initMatrix();
}

sub initPrefs {
	$prefs->init({
		toplevelplaylistname => 'none',
		powerofftime => '01:30',
		appitem => 1,
		limitvolumecontrollevel => 50,
		contextmenusimilartracktitlesbysameartist => 1,
		contextmenusimilartracktitles => 1,
		similaritythreshold => 85,
		rltypematrix => [],
		restorependingrescan => 0,
	});
	$prefs->set('status_exportingtoplaylistfiles', '0');
	$prefs->set('status_backuprestore', '0'); # 0 = idle, 1 = backup in progress, 2 = restore in progress
	$prefs->set('backuprestoreprogresspercentage', '0');
	$prefs->set('backuprestoreresult', '0'); # 0 = no result, 1 = backup success, 2 = backup error, 3 = restore success, 4 = restore error, 5 = restore success, requires rescan

	$prefs->setValidate({'validator' => 'intlimit', 'low' => 0, 'high' => 100}, 'presetVolume');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 0, 'high' => 100}, 'limitvolumecontrollevel');
	$prefs->setValidate({'validator' => \&isTimeOrEmpty}, 'powerofftime');

	$prefs->setChange(sub {
			main::DEBUGLOG && $log->is_debug && $log->debug('Change in toplevelPL config detected. Reinitializing top level PL link.');
			initPLtoplevellink();
		}, 'toplevelplaylistname');
	$prefs->setChange(\&powerOffClientsScheduler, 'enablescheduledclientspoweroff', 'powerofftime');
	$prefs->setChange(sub {
			main::DEBUGLOG && $log->is_debug && $log->debug('Change in comment tag info config matrix detected. Reinitializing trackinfohandler & titleformats.');
			initMatrix();
			Slim::Music::Info::clearFormatDisplayCache();
		}, 'commenttaginfoconfigmatrix');
	$prefs->setChange(sub {
			main::DEBUGLOG && $log->is_debug && $log->debug('De-/reregistering infoprovider zppt_infotrackid');
			Slim::Menu::TrackInfo->deregisterInfoProvider('zppt_infotrackid');
			if ($prefs->get('displaytrackid')) {
				Slim::Menu::TrackInfo->registerInfoProvider('zppt_infotrackid' => (
					parent => 'moreinfo', isa => 'bottom',
					func => sub { return getTrackIdForContextMenu(@_); }
				));
			}
		}, 'displaytrackid');
	$prefs->setChange(sub {
			main::DEBUGLOG && $log->is_debug && $log->debug('De-/reregistering infoprovider ppt_similartracktitlesbysameartist');
			Slim::Menu::TrackInfo->deregisterInfoProvider('ppt_similartracktitlesbysameartist');
			if ($prefs->get('contextmenusimilartracktitlesbysameartist')) {
				Slim::Menu::TrackInfo->registerInfoProvider('ppt_similartracktitlesbysameartist' => (
					before => 'moreinfo',
					func => sub { return _getSimilarTrackTitlesHandler(0, @_); }
				));
			}
		}, 'contextmenusimilartracktitlesbysameartist');
	$prefs->setChange(sub {
			main::DEBUGLOG && $log->is_debug && $log->debug('De-/reregistering infoprovider ppt_similartracktitles');
			Slim::Menu::TrackInfo->deregisterInfoProvider('ppt_similartracktitles');
			if ($prefs->get('contextmenusimilartracktitles')) {
				Slim::Menu::TrackInfo->registerInfoProvider('ppt_similartracktitles' => (
					after => 'ppt_similartracktitlesbysameartist',
					func => sub { return _getSimilarTrackTitlesHandler(1, @_); }
				));
			}
		}, 'contextmenusimilartracktitles');
	$prefs->setChange(sub {
		my ($name, $value, $client) = @_;
		_prefsChangeCheck($client);
	}, 'limitvolumecontrol', 'limitvolumecontrollevel');


	my $i = 1;
	%sortOptionLabels = map { $i++ => $_ } ('Random order', 'Inverted order', 'Artist > album > disc no. > track no.', 'Album > artist > disc no. > track no.', 'Album > disc no. > track no.', 'Genre', 'Year', 'Track number', 'Track title', 'Date added', 'Play count', 'Play count (APC)', 'Date last played', 'Date last played (APC)', 'Rating', 'Dynamic played/skipped value (APC)', 'Track length', 'BPM', 'Bitrate', 'Album artist', 'Composer', 'Conductor', 'Band');
}


sub playlistSortContextMenu {
	my ($client, $url, $obj, $remoteMeta, $tags) = @_;
	$tags ||= {};

	my $playlistID= $obj->id;
	my $playlistName = $obj->name;
	main::DEBUGLOG && $log->is_debug && $log->debug('playlist name = '.$playlistName.' ## playlist url = '.Data::Dump::dump($url));

	if ($tags->{menuMode}) {
		return {
			type => 'redirect',
			jive => {
				actions => {
					go => {
						player => 0,
						cmd => ['potpourri', 'changeplaylisttrackorderoptions', $playlistID, $playlistName],
					},
				}
			},
			name => string('PLUGIN_POTPOURRI_PLSORTORDER_OPTIONS'),
			favorites => 0,
		};
	} else {
		return {
			type => 'redirect',
			name => string('PLUGIN_POTPOURRI_PLSORTORDER_OPTIONS'),
			favorites => 0,
			web => {
				url => 'plugins/PotPourri/playlistsortorderselect?playlistid='.$playlistID.'&playlistname='.$playlistName
			},
		};
	}
}

sub changePLtrackOrder_web {
	my ($client, $params, $callback, $httpClient, $response) = @_;

	my $playlistID = $params->{playlistid};
	my $playlistName = $params->{playlistname};
	main::DEBUGLOG && $log->is_debug && $log->debug('playlistID = '.$playlistID.' ## playlistName = '.Data::Dump::dump($playlistName));

	my $sortOption = $params->{sortoption};
	main::DEBUGLOG && $log->is_debug && $log->debug('sortOption = '.Data::Dump::dump($sortOption));
	$params->{playlistid} = $playlistID;
	$params->{playlistname} = $playlistName;
	$params->{apc_enabled} = 1 if $apc_enabled;

	if ($sortOption) {
		my $failed = changePLtrackOrder($playlistID, $sortOption, $playlistName);
		if ($failed) {
			$params->{failed} = 1;
		} else {
			$params->{orderchanged} = 1;
		}
	}
	return Slim::Web::HTTP::filltemplatefile('plugins/PotPourri/html/playlistsortorderoptions.html', $params);
}

sub changePLtrackOrder_jive_choice {
	my $request = shift;
	my $client = $request->client();

	if (!$request->isQuery([['potpourri'],['changeplaylisttrackorderoptions']])) {
		$log->warn('incorrect command');
		$request->setStatusBadDispatch();
		return;
	}
	if (!defined $client) {
		$log->warn('client required!');
		$request->setStatusNeedsClient();
		return;
	}
	my $playlistID = $request->getParam('_playlistid');
	my $playlistName = $request->getParam('_playlistname');
	main::DEBUGLOG && $log->is_debug && $log->debug('playlistid = '.Data::Dump::dump($playlistID));
	return unless $playlistID;

	my @sortOptionKeys = sort {$a <=> $b} keys (%sortOptionLabels);

	my $windowTitle = string('PLUGIN_POTPOURRI_PLSORTORDER_OPTIONS');
	$request->addResult('window', {text => $windowTitle});

	my $cnt = 0;
	foreach (@sortOptionKeys) {
		next if $sortOptionLabels{$_} =~ '(APC)' && !$apc_enabled;
		my $action = {
			'do' => {
				'player' => 0,
				'cmd' => ['potpourri', 'changeplaylisttrackorder', $playlistID, $_, $playlistName],
			},
			'play' => {
				'player' => 0,
				'cmd' => ['potpourri', 'changeplaylisttrackorder', $playlistID, $_, $playlistName],
			},
		};
		my $displayText = $sortOptionLabels{$_};

		$request->addResultLoop('item_loop', $cnt, 'text', $displayText);
		$request->addResultLoop('item_loop', $cnt, 'style', 'itemNoAction');
		$request->addResultLoop('item_loop', $cnt, 'type', 'redirect');
		$request->addResultLoop('item_loop', $cnt, 'actions', $action);
		$request->addResultLoop('item_loop', $cnt, 'nextWindow', 'parent');
		$cnt++;
	}

	$request->addResult('offset', 0);
	$request->addResult('count', $cnt);
	$request->setStatusDone();
}

sub changePLtrackOrder_jive {
	my $request = shift;
	my $client = $request->client();

	if (!$request->isCommand([['potpourri'],['changeplaylisttrackorder']])) {
		$log->warn('incorrect command');
		$request->setStatusBadDispatch();
		return;
	}
	if (!defined $client) {
		$log->warn('client required!');
		$request->setStatusNeedsClient();
		return;
	}
	my $playlistID = $request->getParam('_playlistid');
	my $sortOption = $request->getParam('_sortoption');
	my $playlistName = $request->getParam('_playlistname');

	return unless $playlistID && $sortOption;
	main::DEBUGLOG && $log->is_debug && $log->debug('playlistid = '.$playlistID.' ## sortOption = '.$sortOption);

	my $failed = changePLtrackOrder($playlistID, $sortOption, $playlistName);

	displayMessage($client, $failed);

	$request->setStatusDone();
}

sub changePLtrackOrder {
	my ($playlistID, $sortOption, $playlistName) = @_;
	if (!$playlistID || !$sortOption) {
		$log->error('Missing playlist id or sort option');
		return 1;
	}

	my $started = time();
	my $playlist = Slim::Schema->find('Playlist', $playlistID);
	return 1 if !blessed($playlist);

	my @PLtracks = $playlist->tracks;
	if (scalar @PLtracks < 2) {
		$log->warn('No sense in reordering playlists with less than 2 tracks');
		return 1;
	}

	## sort playlist tracks
	@PLtracks = sortTracks($sortOption, @PLtracks);

	# update and write playlist
	$playlist->setTracks(\@PLtracks);
	$playlist->update;

	if ($playlist->content_type eq 'ssp') {
		main::DEBUGLOG && $log->is_debug && $log->debug('Writing playlist to disk.');
		Slim::Formats::Playlists->writeList(\@PLtracks, undef, $playlist->url);
	}

	Slim::Schema->forceCommit;
	Slim::Schema->wipeCaches;
	if ($playlistName) {
		main::INFOLOG && $log->is_info && $log->info('Sorting the playlist "'.$playlistName.'" by "'.$sortOptionLabels{$sortOption}.'" took '.(time()-$started).' seconds');
	} else {
		main::INFOLOG && $log->is_info && $log->info('Sorting the playlist by "'.$sortOptionLabels{$sortOption}.'" took '.(time()-$started).' seconds');
	}

	return 0;
}

sub handleFeed {
	my ($client, $callback, $params, $args) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug('client ID:'.$client->name.' ## client ID:'.$client->id);

	my $items = [
		{
			name => cstring($client, 'PLUGIN_POTPOURRI_CLIENTPL_CHANGEORDER').' '.$client->name,
			type => 'link',
			url => \&getSortOptions,
		},
	];
	$callback->({
		items => $items
	});
}

sub getSortOptions {
	my ($client, $cb, $params) = @_;

	my @sortOptionKeys = sort {$a <=> $b} keys (%sortOptionLabels);

	my $sortOptions = [];

	foreach (@sortOptionKeys) {
		next if $sortOptionLabels{$_} =~ '(APC)' && !$apc_enabled;
		push @{$sortOptions}, {
					name => $sortOptionLabels{$_},
					url => \&changeClientPLTrackOrder,
					passthrough => [{
						sortOption => $_,
					}],
				};
	}
	$cb->($sortOptions);
}

sub changeClientPLTrackOrder {
	my ($client, $cb, $params, $args) = @_;
	return if !$client;

	main::INFOLOG && $log->is_info && $log->info('client ID:'.$client->name.' ## client ID:'.$client->id);
	my $started = time();

	my $sortOption = $args->{'sortOption'};
	main::DEBUGLOG && $log->is_debug && $log->debug('sortOption = '.Data::Dump::dump($sortOption));

	my @PLtracks = @{Slim::Player::Playlist::playList($client)};

	if (scalar @PLtracks < 2) {
		$log->warn('No sense in reordering playlists with less than 2 tracks');
		return;
	}

	## sort playlist tracks
	@PLtracks = sortTracks($sortOption, @PLtracks);

	# clear client playlist, add tracks and refresh
	Slim::Player::Playlist::stopAndClear($client);

	Slim::Player::Playlist::addTracks($client, \@PLtracks, 0);
	$client->currentPlaylistModified(1);
	$client->currentPlaylistUpdateTime(Time::HiRes::time());
	Slim::Player::Playlist::refreshPlaylist($client);

	main::INFOLOG && $log->is_info && $log->info('Sorting current playlist of client "'.$client->name.'" by "'.$sortOptionLabels{$sortOption}.'" took '.(time()-$started).' seconds');

	my $items = [
		{
			name => string('PLUGIN_POTPOURRI_CLIENTPL_CHANGEORDER_DONE').' '.$sortOptionLabels{$sortOption},
			type => 'text',
		},
		{
			name => string('PLUGIN_POTPOURRI_CLIENTPL_CHANGEORDER_DONE_INFO'),
			type => 'text',
		},
	];
	$cb->({
		items => $items
	});
}

sub sortTracks {
	my ($sortOption, @tracks) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug('sortOption = '.Data::Dump::dump($sortOption));

	# Randomize
	if ($sortOption == 1) {
		@tracks = shuffle(@tracks);

	# Invert
	} elsif ($sortOption == 2) {
		@tracks = reverse @tracks;

	# By artist > album > disc no. > track no.
	} elsif ($sortOption == 3) {
		@tracks = sort {lc($a->artist->namesort) cmp lc($b->artist->namesort) || lc($a->album->namesort) cmp lc($b->album->namesort) || ($a->disc || 0) <=> ($b->disc || 0) || ($a->tracknum || 0) <=> ($b->tracknum || 0)} @tracks;

	# By album > artist > disc no. > track no.
	} elsif ($sortOption == 4) {
		@tracks = sort {lc($a->album->namesort) cmp lc($b->album->namesort) || lc($a->artist->namesort) cmp lc($b->artist->namesort) || ($a->disc || 0) <=> ($b->disc || 0) || ($a->tracknum || 0) <=> ($b->tracknum || 0)} @tracks;

	# By album > disc no. > track no.
	} elsif ($sortOption == 5) {
		@tracks = sort {lc($a->album->namesort) cmp lc($b->album->namesort) || ($a->disc || 0) <=> ($b->disc || 0) || ($a->tracknum || 0) <=> ($b->tracknum || 0)} @tracks;

	# By first genre
	} elsif ($sortOption == 6) {
		@tracks = sort {lc($a->genre->namesort) cmp lc($b->genre->namesort)} @tracks;

	# By year
	} elsif ($sortOption == 7) {
		@tracks = sort {($a->year || 0) <=> ($b->year || 0)} @tracks;

	# By track number
	} elsif ($sortOption == 8) {
		@tracks = sort {($a->tracknum || 0) <=> ($b->tracknum || 0)} @tracks;

	# By track title
	} elsif ($sortOption == 9) {
		@tracks = sort {lc($a->titlesort) cmp lc($b->titlesort)} @tracks;

	# By date added
	} elsif ($sortOption == 10) {
		@tracks = sort {($a->addedTime || 0) <=> ($b->addedTime || 0)} @tracks;

	# By play count
	} elsif ($sortOption == 11) {
		@tracks = sort {($b->playcount || 0) <=> ($a->playcount || 0)} @tracks;

	# By play count (APC)
	} elsif ($sortOption == 12) {
		my $lookupHash = APCqueryBatch([map { $_->urlmd5 } @tracks], 'playCount');
		@tracks = sort {($lookupHash->{$b->urlmd5} || 0) <=> ($lookupHash->{$a->urlmd5} || 0)} @tracks;

	# By date last played
	} elsif ($sortOption == 13) {
		@tracks = sort {($b->lastplayed || 0) <=> ($a->lastplayed || 0)} @tracks;

	# By date last played (APC)
	} elsif ($sortOption == 14) {
		my $lookupHash = APCqueryBatch([map { $_->urlmd5 } @tracks], 'lastPlayed');
		@tracks = sort {($lookupHash->{$b->urlmd5} || 0) <=> ($lookupHash->{$a->urlmd5} || 0)} @tracks;

	# By rating
	} elsif ($sortOption == 15) {
		@tracks = sort {($a->rating || 0) <=> ($b->rating || 0)} @tracks;

	# By dynamic played/skipped value (DPSV) (APC)
	} elsif ($sortOption == 16) {
		my $lookupHash = APCqueryBatch([map { $_->urlmd5 } @tracks], 'dynPSval');
		@tracks = sort {($lookupHash->{$b->urlmd5} || 0) <=> ($lookupHash->{$a->urlmd5} || 0)} @tracks;

	# By duration
	} elsif ($sortOption == 17) {
		@tracks = sort {($a->secs || 0) <=> ($b->secs || 0)} @tracks;

	# By BPM
	} elsif ($sortOption == 18) {
		@tracks = sort {($a->bpm || 0) <=> ($b->bpm || 0)} @tracks;

	# By bitrate
	} elsif ($sortOption == 19) {
		@tracks = sort {($a->bitrate || 0) <=> ($b->bitrate || 0)} @tracks;

	# By album artist
	} elsif ($sortOption == 20) {
		@tracks = sort {lc($a->album->contributor->namesort) cmp lc($b->album->contributor->namesort)} @tracks;

	# By composer
	} elsif ($sortOption == 21) {
		@tracks = sort {lc($a->composer->namesort) cmp lc($b->composer->namesort)} @tracks;

	# By conductor
	} elsif ($sortOption == 22) {
		@tracks = sort {lc($a->conductor->namesort) cmp lc($b->conductor->namesort)} @tracks;

	# By band
	} elsif ($sortOption == 23) {
		@tracks = sort {lc($a->band->namesort) cmp lc($b->band->namesort)} @tracks;
	}

	return @tracks;
}


# export static playlists with new paths/file extensions
sub exportPlaylistsToFiles {
	my $playlistID = shift;
main::INFOLOG && $log->is_info && $log->info('playlistID = '.Data::Dump::dump($playlistID));

	my $status_exportingtoplaylistfiles = $prefs->get('status_exportingtoplaylistfiles');
	if ($status_exportingtoplaylistfiles == 1) {
		$log->warn('Export is already in progress, please wait for the previous export to finish');
		return;
	}
	$prefs->set('status_exportingtoplaylistfiles', 1);

	my $exportDir = $serverPrefs->get('playlistdir') || Slim::Utils::OSDetect::dirsFor('prefs');
	my $started = time();

	my $playlist = Slim::Schema->find('Playlist', $playlistID);
	return if !blessed($playlist);

	my @PLtracks = $playlist->tracks;
	my $trackCount = scalar(@PLtracks);

	if ($trackCount > 0) {
		my $exporttimestamp = strftime "%Y-%m-%d %H:%M:%S", localtime time;
		my $filename_timestamp = strftime "%Y%m%d-%H%M", localtime time;
		my $PLfilename = 'PPT_Export_'.$filename_timestamp.'_'.$playlist->title.'.m3u.txt';

		my $filename = catfile($exportDir, $PLfilename);
		my $output = FileHandle->new($filename, '>:utf8') or do {
			$log->error('Could not open '.$filename.' for writing. Does LMS have read/write permissions (755) for the LMS playlist folder?');
			$prefs->set('status_exportingtoplaylistfiles', 0);
			return;
		};
		print $output '#EXTM3U'."\n";
		print $output '# exported with \'PotPourri\' LMS plugin ('.$exporttimestamp.")\n";
		print $output '# contains '.$trackCount.($trackCount == 1 ? ' track' : ' tracks')."\n\n";
		for my $thisTrack (@PLtracks) {
			my $thisTrackURL = $thisTrack->get('url');
			my $thisTrackURL_extURL = changeExportFilePath($thisTrackURL, 1) if ($thisTrack->get('remote') != 1);
			print $output '#EXTURL:'.$thisTrackURL_extURL."\n" if $thisTrackURL_extURL && $thisTrackURL_extURL ne '';

			my $thisTrackPath = Slim::Utils::Unicode::utf8decode_locale(pathForItem($thisTrackURL));
			$thisTrackPath = changeExportFilePath($thisTrackPath) if ($thisTrack->get('remote') != 1);

			print $output $thisTrackPath."\n";
		}
		close $output;
	}

	main::DEBUGLOG && $log->is_debug && $log->debug('TOTAL number of tracks exported: '.$trackCount);
	$prefs->set('status_exportingtoplaylistfiles', 0);
	main::DEBUGLOG && $log->is_debug && $log->debug('Export completed after '.(time() - $started).' seconds.');
}

sub changeExportFilePath {
	my $trackURL = shift;
	my $isEXTURL = shift;
	my $exportbasefilepathmatrix = $prefs->get('exportbasefilepathmatrix');

	if (scalar @{$exportbasefilepathmatrix} > 0) {
		my $oldtrackURL = $trackURL;
		my $escaped_trackURL = escape($trackURL);
		my $exportextension = $prefs->get('exportextension');
		my $exportExtensionExceptionsString = $prefs->get('exportextensionexceptions');

		foreach my $thispath (@{$exportbasefilepathmatrix}) {
			my $lmsbasepath = $thispath->{'lmsbasepath'};
			main::INFOLOG && $log->is_info && $log->info("\n\n\nisEXTURL = ".Data::Dump::dump($isEXTURL));
			main::INFOLOG && $log->is_info && $log->info('trackURL = '.Data::Dump::dump($oldtrackURL));
			main::INFOLOG && $log->is_info && $log->info('escaped_trackURL = '.$escaped_trackURL);
			if ($isEXTURL) {
				$lmsbasepath =~ s/\\/\//isg;
				$escaped_trackURL =~ s/%2520/%20/isg;
			}
			main::INFOLOG && $log->is_info && $log->info('escaped_trackURL after EXTURL regex = '.$escaped_trackURL);

			my $escaped_lmsbasepath = escape($lmsbasepath);
			main::INFOLOG && $log->is_info && $log->info('escaped_lmsbasepath = '.$escaped_lmsbasepath);

			if (($escaped_trackURL =~ $escaped_lmsbasepath) && (defined ($thispath->{'substitutebasepath'})) && (($thispath->{'substitutebasepath'}) ne '')) {
				my $substitutebasepath = $thispath->{'substitutebasepath'};
				main::INFOLOG && $log->is_info && $log->info('substitutebasepath = '.$substitutebasepath);
				if ($isEXTURL) {
					$substitutebasepath =~ s/\\/\//isg;
				}
				my $escaped_substitutebasepath = escape($substitutebasepath);
				main::INFOLOG && $log->is_info && $log->info('escaped_substitutebasepath = '.$escaped_substitutebasepath);

				if (defined $exportextension && $exportextension ne '') {
					my ($LMSfileExtension) = $escaped_trackURL =~ /(\.[^.]*)$/;
					$LMSfileExtension =~ s/\.//s;
					main::INFOLOG && $log->is_info && $log->info("LMS file extension is '$LMSfileExtension'");

					# file extension replacement - exceptions
					my %extensionExceptionsHash;
					if (defined $exportExtensionExceptionsString && $exportExtensionExceptionsString ne '') {
						$exportExtensionExceptionsString =~ s/ //g;
						%extensionExceptionsHash = map {$_ => 1} (split /,/, lc($exportExtensionExceptionsString));
						main::DEBUGLOG && $log->is_debug && $log->debug('extensionExceptionsHash = '.Data::Dump::dump(\%extensionExceptionsHash));
					}

					if ((scalar keys %extensionExceptionsHash > 0) && $extensionExceptionsHash{lc($LMSfileExtension)}) {
						main::INFOLOG && $log->is_info && $log->info("The file extension '$LMSfileExtension' is not replaced because it is included in the list of exceptions.");
					} else {
						$escaped_trackURL =~ s/\.[^.]*$/\.$exportextension/isg;
					}
				}

				$escaped_trackURL =~ s/$escaped_lmsbasepath/$escaped_substitutebasepath/isg;
				main::INFOLOG && $log->is_info && $log->info('escaped_trackURL AFTER regex replacing = '.$escaped_trackURL);

				$trackURL = Encode::decode('utf8', unescape($escaped_trackURL));
				main::INFOLOG && $log->is_info && $log->info('UNescaped trackURL = '.$trackURL);

				if ($isEXTURL) {
					$trackURL =~ s/ /%20/isg;
				} else {
					$trackURL = Slim::Utils::Unicode::utf8decode_locale($trackURL);
				}
				main::INFOLOG && $log->is_info && $log->info('old url: '.$oldtrackURL."\nlmsbasepath = ".$lmsbasepath."\nsubstitutebasepath = ".$substitutebasepath."\nnew url = ".$trackURL);
			}
		}
	}
	return $trackURL;
}

sub initExportBaseFilePathMatrix {
	# get LMS music dirs
	my $lmsmusicdirs = getMusicDirs();
	my $exportbasefilepathmatrix = $prefs->get('exportbasefilepathmatrix');
	if (!defined $exportbasefilepathmatrix) {
		my $n = 0;
		foreach my $musicdir (@{$lmsmusicdirs}) {
			push(@{$exportbasefilepathmatrix}, {lmsbasepath => $musicdir, substitutebasepath => ''});
			$n++;
		}
		$prefs->set('exportbasefilepathmatrix', $exportbasefilepathmatrix);
	} else {
		# add new music dirs as options if not in list
		my @currentlmsbasefilepaths;
		foreach my $thispath (@{$exportbasefilepathmatrix}) {
			push (@currentlmsbasefilepaths, $thispath->{'lmsbasepath'});
		}

		my %seen;
		@seen{@currentlmsbasefilepaths} = ();

		foreach my $newdir (@{$lmsmusicdirs}) {
			push (@{$exportbasefilepathmatrix}, {lmsbasepath => $newdir, substitutebasepath => ''}) unless exists $seen{$newdir};
		}
		$prefs->set('exportbasefilepathmatrix', $exportbasefilepathmatrix);
	}
}


# use comment tag info for song info & title formats
sub initMatrix {
	main::DEBUGLOG && $log->is_debug && $log->debug('Start initializing trackinfohandler & titleformats.');
	my $configmatrix = $prefs->get('commenttaginfoconfigmatrix');

	if (keys %{$configmatrix} > 0) {
		foreach my $thisconfig (keys %{$configmatrix}) {
			my $enabled = $configmatrix->{$thisconfig}->{'enabled'};
			next if (!defined $enabled);

			my $thisconfigID = $thisconfig;
			main::DEBUGLOG && $log->is_debug && $log->debug('thisconfigID = '.$thisconfigID);
			my $regID = 'PPT_TIHregID_'.$thisconfigID;
			main::DEBUGLOG && $log->is_debug && $log->debug('trackinfohandler ID = '.$regID);
			Slim::Menu::TrackInfo->deregisterInfoProvider($regID);

			my $searchstring = $configmatrix->{$thisconfig}->{'searchstring'};
			my $contextmenucategoryname = $configmatrix->{$thisconfig}->{'contextmenucategoryname'};
			my $contextmenucategorycontent = $configmatrix->{$thisconfig}->{'contextmenucategorycontent'};

			if (defined $searchstring && defined $contextmenucategoryname && defined $contextmenucategorycontent) {
				my $contextmenuposition = $configmatrix->{$thisconfig}->{'contextmenuposition'};
				my $possiblecontextmenupositions = [
					['after', 'artwork'], # 0
					['after', 'bottom'], # 1
					['parent', 'moreinfo', 'isa', 'top'], # 2
					['parent', 'moreinfo', 'isa', 'bottom'], # 3
				];
				my $thisPos = $possiblecontextmenupositions->[$contextmenuposition];
				Slim::Menu::TrackInfo->registerInfoProvider($regID => (
					@{$thisPos},
					func => sub {
						return getTrackInfo(@_,$thisconfigID);
					}
				));
			}
			my $titleformatname = $configmatrix->{$thisconfig}->{'titleformatname'};
			my $titleformatdisplaystring = $configmatrix->{$thisconfig}->{'titleformatdisplaystring'};
			if (defined $searchstring && defined $titleformatname && defined $titleformatdisplaystring) {
				my $TF_name = 'PPT_'.uc(trim_all($titleformatname));
				main::DEBUGLOG && $log->is_debug && $log->debug('titleformat name = '.$TF_name);
				addTitleFormat($TF_name);
				Slim::Music::TitleFormatter::addFormat($TF_name, sub {
				return getTitleFormat(@_, $thisconfigID);
				}, 1);
			}
		}
	}
	main::DEBUGLOG && $log->is_debug && $log->debug('Finished initializing trackinfohandler & titleformats.');
}

sub getTrackInfo {
	my ($client, $url, $track, $remoteMeta, $tags, $filter, $thisconfigID) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug('thisconfigID = '.$thisconfigID);

	if (Slim::Music::Import->stillScanning) {
		$log->warn('Warning: not available until library scan is completed');
		return;
	}

	# check if remote track is part of online library
	if ((Slim::Music::Info::isRemoteURL($url) == 1)) {
		main::DEBUGLOG && $log->is_debug && $log->debug('ignoring remote track without comments tag: '.$url);
		return;
	}

	# check for dead/moved local tracks
	if ((Slim::Music::Info::isRemoteURL($url) != 1) && (!defined($track->filesize))) {
		main::DEBUGLOG && $log->is_debug && $log->debug('track dead or moved??? Track URL: '.$url);
		return;
	}

	my $configmatrix = $prefs->get('commenttaginfoconfigmatrix');
	my $thisconfig = $configmatrix->{$thisconfigID};
		if (($thisconfig->{'searchstring'}) && ($thisconfig->{'contextmenucategoryname'}) && ($thisconfig->{'contextmenucategorycontent'})) {
			my $itemname = $thisconfig->{'contextmenucategoryname'};
			my $itemvalue = $thisconfig->{'contextmenucategorycontent'};
			my $thiscomment = $track->comment;

			if (defined $thiscomment && $thiscomment ne '') {
				if (index(lc($thiscomment), lc($thisconfig->{'searchstring'})) != -1) {

					main::DEBUGLOG && $log->is_debug && $log->debug('text = '.$itemname.': '.$itemvalue);
					return {
						type => 'text',
						name => $itemname.': '.$itemvalue,
						itemvalue => $itemvalue,
						itemid => $track->id,
					};
				}
			}
		}
	return;
}

sub getTitleFormat {
	my $track = shift;
	my $thisconfigID = shift;
	my $TF_string = '';

	if (Slim::Music::Import->stillScanning) {
		$log->warn('Warning: not available until library scan is completed');
		return $TF_string;
	}
	main::DEBUGLOG && $log->is_debug && $log->debug('getting value for title format ID = '.$thisconfigID);

	if ($track && !blessed($track)) {
		main::DEBUGLOG && $log->is_debug && $log->debug('track is not blessed');
		$track = Slim::Schema->find('Track', $track->{id});
		if (!blessed($track)) {
			main::DEBUGLOG && $log->is_debug && $log->debug('No track object found');
			return $TF_string;
		}
	}
	my $trackURL = $track->url;

	# check if remote track is part of online library
	if ((Slim::Music::Info::isRemoteURL($trackURL) == 1)) {
		main::DEBUGLOG && $log->is_debug && $log->debug('ignoring remote track without comments tag: '.$trackURL);
		return $TF_string;
	}

	# check for dead/moved local tracks
	if ((Slim::Music::Info::isRemoteURL($trackURL) != 1) && (!defined($track->filesize))) {
		main::DEBUGLOG && $log->is_debug && $log->debug('track dead or moved??? Track URL: '.$trackURL);
		return $TF_string;
	}

	my $configmatrix = $prefs->get('commenttaginfoconfigmatrix');
	my $thisconfig = $configmatrix->{$thisconfigID};
	my $titleformatname = $thisconfig->{'titleformatname'};
	my $titleformatdisplaystring = $thisconfig->{'titleformatdisplaystring'};
	if (($titleformatname ne '') && ($titleformatdisplaystring ne '')) {
		my $thiscomment = $track->comment;
		if (defined $thiscomment && $thiscomment ne '') {
			if (index(lc($thiscomment), lc($thisconfig->{'searchstring'})) != -1) {
				$TF_string = $titleformatdisplaystring;
			}
		}
	}
	main::DEBUGLOG && $log->is_debug && $log->debug('returned title format display string for track = '.Data::Dump::dump($TF_string));
	return $TF_string;
}

sub addTitleFormat {
	my $titleformat = shift;
	my $titleFormats = $serverPrefs->get('titleFormat');
	foreach my $format (@{$titleFormats}) {
		if ($titleformat eq $format) {
			return;
		}
	}
	push @{$titleFormats},$titleformat;
	$serverPrefs->set('titleFormat',$titleFormats);
}


# player volume level: power on, fixed / capped
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
			main::DEBUGLOG && $log->is_debug && $log->debug("allowRaise disabled. Current: ".$curVolume." Target: ".$volume);
			return if ($curVolume <= $volume);
		}
		main::DEBUGLOG && $log->is_debug && $log->debug("Setting volume for client '".$client->name()."' to ".($enabledSetStartVolumeLevel == 2 ? "last" : "preset")." $volume");
		$client->volume($volume);
	} else {
		$prefs->client($client)->set('lastVolume', $curVolume);
		main::DEBUGLOG && $log->is_debug && $log->debug("Saving last volume $curVolume for client '".$client->name()."'");
	}
}

sub _limitVolumeControl {
	my @args = @_;
	my $request = $args[0];
	my $client = $request->client();
	if (!$client) {
		$log->warn('NO client!!!');
		return;
	}

	my $clientPrefs = $prefs->client($client);
	my $limitVolumeControl = $clientPrefs->get('limitvolumecontrol');
	main::DEBUGLOG && $log->is_debug && $log->debug('------ '.($client->name ? 'Player "'.$client->name.'": ': '').'request for volume change detected ------');
	main::DEBUGLOG && $log->is_debug && $log->debug('limitVolumeControl mode = '.Data::Dump::dump($limitVolumeControl).' (0 = disabled, 1 = fixed, 2 = capped)');

	my $newValue = $request->getParam('_newvalue');
	main::DEBUGLOG && $log->is_debug && $log->debug('raw newValue from request = '.Data::Dump::dump($newValue));

	# old players report new value as incremental value change
	if ($newValue =~ /^[\+\-]/) {
		my $oldValue = $client->volume;
		main::DEBUGLOG && $log->is_debug && $log->debug('old volume value = '.Data::Dump::dump($oldValue));
		$newValue = $oldValue + $newValue;
	}
	main::DEBUGLOG && $log->is_debug && $log->debug('requested new volume = '.Data::Dump::dump($newValue));

	if ($limitVolumeControl) {
		my $limitVolumeControlLevel = $clientPrefs->get('limitvolumecontrollevel');
		main::DEBUGLOG && $log->is_debug && $log->debug(($limitVolumeControl == 1 ? 'fixed volume' : 'max. volume').' set in player prefs = '.Data::Dump::dump($limitVolumeControlLevel));

		# 1 = locked/fixed, 2 = capped at max level
		if ((($limitVolumeControl == 1) && ($newValue != $limitVolumeControlLevel)) ||
		(($limitVolumeControl == 2) && ($newValue > $limitVolumeControlLevel)))
		{
			my $deviceMsg = string('PLUGIN_POTPOURRI_PLAYER_VOLUMECONTROL_FEEDBACK').' '.(($limitVolumeControl == 1) ? string('PLUGIN_POTPOURRI_PLAYER_VOLUMECONTROL_FEEDBACK_LOCKED') : string('PLUGIN_POTPOURRI_PLAYER_VOLUMECONTROL_FEEDBACK_CAPPED'))." $limitVolumeControlLevel";
			my $logMsg = ($client->name ? 'Player "'.$client->name.'": ': '')."requested player volume $newValue ".($limitVolumeControl == 1 ? 'is different from fixed' : 'greater than max.'). " player volume $limitVolumeControlLevel. Resetting player volume to $limitVolumeControlLevel.";
			Slim::Utils::Timers::killTimers($client, \&_resetVolume);
			Slim::Utils::Timers::setTimer($client,Time::HiRes::time() + 0.05,\&_resetVolume, $limitVolumeControlLevel, $deviceMsg, $logMsg);

			$request->setStatusDone;
			return;
		} else {
			my $logMsg = ($client->name ? 'Player "'.$client->name.'": ': '')."NO action required. Requested player volume $newValue ".($limitVolumeControl == 1 ? '= fixed' : '<= max.'). " player volume $limitVolumeControlLevel.";
			Slim::Utils::Timers::killTimers($client, \&_volFeedback);
			Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 1,\&_volFeedback, undef, undef, $logMsg);
		}
	} else {
		Slim::Utils::Timers::killTimers($client, \&_volFeedback);
		Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 1,\&_volFeedback, undef, undef, ($client->name ? 'Player "'.$client->name.'": ': '').'NO action required. Player volume not fixed or capped.');
	}
	# else call the original function
	main::DEBUGLOG && $log->is_debug && $log->debug('Calling original mixer function');
	return &$originalMixerVolumeCommand(@args);
}

sub _prefsChangeCheck {
	my $client = shift;
	return unless $client;

	my $clientPrefs = $prefs->client($client);
	my $limitVolumeControl = $clientPrefs->get('limitvolumecontrol');
	main::DEBUGLOG && $log->is_debug && $log->debug('limitVolumeControl mode: '.Data::Dump::dump($limitVolumeControl));
	if ($limitVolumeControl) {
		main::INFOLOG && $log->is_info && $log->info("set pref to limitVolumeControl mode: ".($limitVolumeControl == 1 ? 'fixed volume' : 'max. volume / capped'));
		my $limitVolumeControlLevel = $clientPrefs->get('limitvolumecontrollevel');
		main::DEBUGLOG && $log->is_debug && $log->debug('limitVolumeControlLevel = '.Data::Dump::dump($limitVolumeControlLevel));
		my $currentVolume = $client->volume();
		main::DEBUGLOG && $log->is_debug && $log->debug('currentVolume of client = '.Data::Dump::dump($currentVolume));

		if ((($limitVolumeControl == 1) && ($currentVolume != $limitVolumeControlLevel)) ||
		(($limitVolumeControl == 2) && ($currentVolume > $limitVolumeControlLevel)))
		{
			main::INFOLOG && $log->is_info && $log->info("post pref change: resetting player volume to $limitVolumeControlLevel because the current player volume $currentVolume ".($limitVolumeControl == 1 ? 'was different (fixed mode)' : 'exceeded the max. volume'));
			Slim::Utils::Timers::killTimers($client, \&_resetVolume);
			Slim::Utils::Timers::setTimer($client,Time::HiRes::time() + 0.05,\&_resetVolume, $limitVolumeControlLevel);
		}
	} else {
		main::INFOLOG && $log->is_info && $log->info('set pref to limitVolumeControl mode: disabled / no restrictions');
	}
}

sub _resetVolume {
	my ($client, $limitVolumeControlLevel, $deviceMsg, $logMsg) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug('Resetting volume to '.Data::Dump::dump($limitVolumeControlLevel));
	$client->volume($limitVolumeControlLevel);
	Slim::Utils::Timers::killTimers($client, \&_volFeedback);
	Slim::Utils::Timers::setTimer($client,Time::HiRes::time() + 1,\&_volFeedback, $limitVolumeControlLevel, $deviceMsg, $logMsg);
}

sub _volFeedback {
	my ($client, $limitVolumeControlLevel, $deviceMsg, $logMsg) = @_;

	if ($deviceMsg) {
		if (Slim::Buttons::Common::mode($client) !~ /^SCREENSAVER./) {
			$client->showBriefly({'line' => [string('PLUGIN_POTPOURRI'), $deviceMsg]}, 4);
		}
	}
	# set it again, just to make sure
	$client->volume($limitVolumeControlLevel) if $limitVolumeControlLevel;

	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 1, sub {
		if ($deviceMsg && $material_enabled) {
			Slim::Control::Request::executeRequest(undef, ['material-skin', 'send-notif', 'type:info', 'msg:'.$deviceMsg, 'client:'.$client->id, 'timeout:4']);
		}
		main::INFOLOG && $log->is_info && $log->info($logMsg);
		main::DEBUGLOG && $log->is_debug && $log->debug('Current volume for player '.Data::Dump::dump($client->name).' is now at '.Data::Dump::dump($client->volume));
	});
}


# track context menu: show tracks with similar track titles by same artist, ordered by lastPlayed desc
sub _getSimilarTrackTitlesHandler {
	my ($anyArtist, $client, $url, $obj, $remoteMeta, $tags) = @_;
	$tags ||= {};

	my $trackID= $obj->id;
	main::DEBUGLOG && $log->is_debug && $log->debug('trackID = '.Data::Dump::dump($trackID));

	if ((Slim::Music::Info::isRemoteURL($url) == 1) && (!defined($obj->extid))) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Track is remote but not part of LMS library. Track URL: '.$url);
		return;
	}

	my $cmdname = $anyArtist ? 'similartracktitles' : 'similartracktitlesbysameartist';
	my $stringkey = $anyArtist ? 'PLUGIN_POTPOURRI_CONTEXTMENU_SIMILARTRACKTITLES' : 'PLUGIN_POTPOURRI_CONTEXTMENU_SIMILARTRACKTITLESBYARTIST';

	if ($tags->{menuMode}) {
		return {
			type => 'redirect',
			jive => {
				actions => {
					go => {
						player => 0,
						cmd => ['potpourri', $cmdname, $trackID],
					},
				}
			},
			name => string($stringkey),
			favorites => 0,
			hide => 'ip3k',
		};
	} else {
		return {
			type => 'redirect',
			name => string($stringkey),
			favorites => 0,
			trackid => $trackID,
			hide => 'ip3k',
			web => {
				url => 'plugins/PotPourri/html/showsimilartracktitleslist.html?trackid='.$trackID.($anyArtist ? '&scope=any' : '')
			},
		};
	}
}

sub _getSimilarTrackTitles_web {
	my ($client, $params, $callback, $httpClient, $response) = @_;

	## execute action if action and action track id(s) provided
	my $action = $params->{'action'};
	main::DEBUGLOG && $log->is_debug && $log->debug('action = '.Data::Dump::dump($action));
	my $actionTrackIDs = $params->{'actiontrackids'};
	main::DEBUGLOG && $log->is_debug && $log->debug('actionTrackIDs = '.Data::Dump::dump($actionTrackIDs));

	if ($action && ($action eq 'load' || $action eq 'insert' || $action eq 'add') && $actionTrackIDs) {
		if (!$client) {
			$log->warn('Client required. Can\'t proceed.');
			return;
		}
		$client->execute(['playlistcontrol', 'cmd:'.$action, 'track_id:'.$actionTrackIDs]);
	}

	my $trackID = $params->{trackid} || 0;
	main::DEBUGLOG && $log->is_debug && $log->debug('params->{trackid} = '.Data::Dump::dump($params->{trackid}));

	my $anyArtist = ($params->{scope} && $params->{scope} eq 'any') ? 1 : 0;
	my $similarTracks = $anyArtist ? _getSimilarTrackTitles($trackID) : _getSimilarTrackTitlesBySameArtist($trackID);
	$similarTracks //= [];

	my @similartracks_webpage = ();
	my @alltrackids = ();

	foreach my $similarTrack (@{$similarTracks}) {
		my $track_id = $similarTrack->id;
		my $tracktitle = trimStringLength($similarTrack->title, 70);
		if ($rl_enabled && $similarTrack->rating) {
			$tracktitle .= getRatingTextLine($similarTrack->rating);
		}
		my $artworkID = $similarTrack->album->artwork;
		my $artistname = trimStringLength($similarTrack->artist->name, 80);
		my $artistID = $similarTrack->artist->id;
		my $albumname = trimStringLength($similarTrack->album->name, 80);
		my $albumID = $similarTrack->album->id;

		push (@similartracks_webpage, {trackid => $track_id, tracktitle => $tracktitle, artistname => $artistname, artistID => $artistID, albumname => $albumname, albumID => $albumID, artworkid => $artworkID});
		push @alltrackids, $track_id;
	}
	my $listalltrackids = join (',', @alltrackids);
	$params->{trackid} = $trackID;
	$params->{trackcount} = scalar(@similartracks_webpage);
	$params->{alltrackids} = $listalltrackids;
	$params->{similartracktitles} = \@similartracks_webpage;
	$params->{pagetitlestringkey} = $anyArtist ? 'PLUGIN_POTPOURRI_CONTEXTMENU_SIMILARTRACKTITLES' : 'PLUGIN_POTPOURRI_CONTEXTMENU_SIMILARTRACKTITLESBYARTIST';
	return Slim::Web::HTTP::filltemplatefile('plugins/PotPourri/html/showsimilartracktitleslist.html', $params);
}

sub _getSimilarTrackTitles_jive {
	my $request = shift;
	my $client = $request->client();

	my $anyArtist = $request->isCommand([['potpourri'],['similartracktitles']]) ? 1 : 0;

	unless ($anyArtist || $request->isCommand([['potpourri'],['similartracktitlesbysameartist']])) {
		$log->warn('incorrect command');
		$request->setStatusBadDispatch();
		return;
	}
	if (!defined $client) {
		$log->warn('client required!');
		$request->setStatusNeedsClient();
		return;
	}
	my $trackID = $request->getParam('_trackid');

	return unless $trackID;
	main::DEBUGLOG && $log->is_debug && $log->debug('trackID = '.$trackID);

	my $similarTracks = $anyArtist ? _getSimilarTrackTitles($trackID) : _getSimilarTrackTitlesBySameArtist($trackID);

	my %menuStyle = ();
	$menuStyle{'titleStyle'} = 'mymusic';
	$menuStyle{'menuStyle'} = 'album';
	$menuStyle{'windowStyle'} = 'icon_list';
	$menuStyle{'text'} = $anyArtist ? string('PLUGIN_POTPOURRI_CONTEXTMENU_SIMILARTRACKTITLES') : string('PLUGIN_POTPOURRI_CONTEXTMENU_SIMILARTRACKTITLESBYARTIST');
	$request->addResult('window',\%menuStyle);

	if (!scalar @{$similarTracks}) {
		main::DEBUGLOG && $log->is_debug && $log->debug('No tracks with similar track titles found for trackID: '.$trackID);
		$request->addResultLoop('item_loop', 0, 'text', $anyArtist ? string('PLUGIN_POTPOURRI_CONTEXTMENU_NOSIMILARTRACKTITLESFOUND_ANYARTIST') : string('PLUGIN_POTPOURRI_CONTEXTMENU_NOSIMILARTRACKTITLESFOUND'));
		$request->addResultLoop('item_loop', 0, 'style', 'itemNoAction');
		$request->addResult('offset', 0);
		$request->addResult('count', 1);
		$request->setStatusDone();
		return;
	}

	my $cnt = 0;
	my $trackCount = scalar(@{$similarTracks});
	if ($trackCount > 1) {
		$cnt = 1;
	}
	my @alltrackids = ();

	foreach my $similarTrack (@{$similarTracks}) {
		if ($similarTrack->coverid) {
			$request->addResultLoop('item_loop', $cnt, 'icon-id', $similarTrack->coverid);
		} else {
			$request->addResultLoop('item_loop', $cnt, 'icon', 'plugins/PotPourri/html/images/coverplaceholder.png');
		}
		push @alltrackids, $similarTrack->id;

		my $tracktitle = trimStringLength($similarTrack->title, 60);
		if ($rl_enabled && $similarTrack->rating) {
			$tracktitle .= getRatingTextLine($similarTrack->rating);
		}
		my $sepchar = HTML::Entities::decode_entities('&#x2022;'); # "bullet"
		my $artistname = $similarTrack->artist->name;
		$artistname = trimStringLength($artistname, 70);
		my $albumname = $similarTrack->album->name;
		$albumname = trimStringLength($albumname, 70);
		my $returntext = $tracktitle."\n".$artistname.' '.$sepchar.' '.$albumname;

		my $actions = {
			'go' => {
				'player' => 0,
				'cmd' => ['potpourri', 'actionsmenu', 'track_id:'.$similarTrack->id, 'allsongs:0'],
			},
		};

		$request->addResultLoop('item_loop', $cnt, 'type', 'redirect');
		$request->addResultLoop('item_loop', $cnt, 'actions', $actions);
		$request->addResultLoop('item_loop', $cnt, 'text', $returntext);
		$cnt++;
	}

	if ($trackCount > 1) {
		my $listalltrackids = join (',', @alltrackids);
		my $actions = {
			'go' => {
				'player' => 0,
				'cmd' => ['potpourri', 'actionsmenu', 'track_id:'.$listalltrackids, 'allsongs:1'],
			},
		};
		$request->addResultLoop('item_loop', 0, 'type', 'redirect');
		$request->addResultLoop('item_loop', 0, 'actions', $actions);
		$request->addResultLoop('item_loop', 0, 'icon', 'plugins/PotPourri/html/images/coverplaceholder.png');
		$request->addResultLoop('item_loop', 0, 'text', string('PLUGIN_POTPOURRI_MENUS_TRACKS_ALLSONGS').' ('.$trackCount.')');
		$cnt++;
	}

	$request->addResult('offset', 0);
	$request->addResult('count', $cnt);
	$request->setStatusDone();
}

sub _getActionsMenu {
	my $request = shift;
	if (!$request->isQuery([['potpourri'],['actionsmenu']])) {
		$log->warn('incorrect command');
		$request->setStatusBadDispatch();
		return;
	}

	my $trackID = $request->getParam('track_id');
	my $allsongs = $request->getParam('allsongs');

	$request->addResult('window', {
		menustyle => 'album',
	});

	my $actionsmenuitems = [
		{
			itemtext => string('PLUGIN_POTPOURRI_MENUS_ACTIONMENU_PLAYNOW'),
			itemcmd1 => 'playlistcontrol',
			itemcmd2 => 'load'
		},
		{
			itemtext => string('PLUGIN_POTPOURRI_MENUS_ACTIONMENU_PLAYNEXT'),
			itemcmd1 => 'playlistcontrol',
			itemcmd2 => 'insert'
		},
		{
			itemtext => string('PLUGIN_POTPOURRI_MENUS_ACTIONMENU_APPEND'),
			itemcmd1 => 'playlistcontrol',
			itemcmd2 => 'add'
		},
		{
			itemtext => string('PLUGIN_POTPOURRI_MENUS_ACTIONMENU_MOREINFO'),
			itemcmd1 => 'trackinfo',
			itemcmd2 => 'items'
		}];

	my $cnt = 0;
	foreach my $menuitem (@{$actionsmenuitems}) {
		my $menuitemtext = $menuitem->{'itemtext'};
		my $menuitemcmd1 = $menuitem->{'itemcmd1'};
		my $menuitemcmd2 = $menuitem->{'itemcmd2'};
		my $actions;

		unless (($menuitemcmd1 eq 'trackinfo') && ($allsongs == 1)) {
			if ($menuitemcmd1 eq 'trackinfo') {
				my %itemParams = (
					'track_id' => $trackID,
					'menu' => 1,
					'usecontextmenu' => 1,
				);
				$actions = {
					'go' => {
						'player' => 0,
						'cmd' => [$menuitemcmd1, $menuitemcmd2],
						'params' => {
							'menu' => 1,
							'track_id' => $trackID,
						},
					},
					'play' => {
						'player' => 0,
						'cmd' => [$menuitemcmd1, $menuitemcmd2],
						'params' => {
							'menu' => 1,
							'track_id' => $trackID,
						},
					}
				};
			} else {
				$actions = {
					'go' => {
						'player' => 0,
						'cmd' => [$menuitemcmd1, 'cmd:'.$menuitemcmd2, 'track_id:'.$trackID],
					},
					'play' => {
						'player' => 0,
						'cmd' => [$menuitemcmd1, 'cmd:'.$menuitemcmd2, 'track_id:'.$trackID],
					}
				};
				$request->addResultLoop('item_loop',$cnt,'nextWindow','parent');
			}

			$request->addResultLoop('item_loop',$cnt,'actions',$actions);
			$request->addResultLoop('item_loop',$cnt,'text',$menuitemtext);
			$request->addResultLoop('item_loop',$cnt,'style', 'itemplay') unless $menuitemcmd1 eq 'trackinfo';
			$cnt++;
		}
	}
	$request->addResult('offset',0);
	$request->addResult('count',$cnt);
	$request->setStatusDone();
}

sub _getSimilarTrackTitlesBySameArtist {
	require String::LCSS;
	my $curTrackID = shift;
	return if !$curTrackID;
	my $curTrack = Slim::Schema->rs('Track')->find($curTrackID);

	my $started = time();
	my $curTitle = $curTrack->title;
	my $curTitleNormalised = normaliseTrackTitle($curTitle);
	my $artist = $curTrack->artist;
	my $similarTracks = [];

	if (defined($artist) && defined($curTitle)) {
		my $similarityThreshold = $prefs->get('similaritythreshold') // 85;
		my $dbh = Slim::Schema->dbh;
		my $sth = $dbh->prepare("select tracks.id,tracks.title,tracks.titlesearch from tracks join contributor_track on tracks.id = contributor_track.track and contributor_track.contributor = ? left join tracks_persistent on tracks.urlmd5 = tracks_persistent.urlmd5 where tracks.id != ? group by tracks.id order by ifnull(tracks_persistent.lastPlayed,0) desc");
		eval {
			$sth->bind_param(1, $artist->id);
			$sth->bind_param(2, $curTrack->id);
			$sth->execute();
			$similarTracks = _filterSimilarTracksByLCSS($sth, $curTitleNormalised, $curTitle, $similarityThreshold);
		};
		if ($@) {
			$log->error("Error executing SQL: $@");
		}
		$sth->finish();
		main::DEBUGLOG && $log->is_debug && $log->debug('Exec time = '.(time()-$started).' secs.');
	}
	return $similarTracks;
}

sub _getSimilarTrackTitles {
	require String::LCSS;
	my $curTrackID = shift;
	return if !$curTrackID;
	my $curTrack = Slim::Schema->rs('Track')->find($curTrackID);

	my $started = time();
	my $curTitle = $curTrack->title;
	my $curTitleNormalised = normaliseTrackTitle($curTitle);
	my $similarTracks = [];

	if (defined($curTitle) && defined($curTitleNormalised) && length($curTitleNormalised) > 3) {
		my $similarityThreshold = $prefs->get('similaritythreshold') // 85;
		my $maxCandidates = 300;
		my $dbh = Slim::Schema->dbh;
		my $sth = $dbh->prepare("select tracks.id,tracks.title,tracks.titlesearch from tracks where tracks.titlesearch LIKE ? and tracks.id != ? order by tracks.titlesearch limit ?");
		eval {
			$sth->bind_param(1, '%'.$curTitleNormalised.'%');
			$sth->bind_param(2, $curTrack->id);
			$sth->bind_param(3, $maxCandidates);
			$sth->execute();
			$similarTracks = _filterSimilarTracksByLCSS($sth, $curTitleNormalised, $curTitle, $similarityThreshold);
		};
		if ($@) {
			$log->error("Error executing SQL: $@");
		}
		$sth->finish();
		@{$similarTracks} = sort {lc($a->artist->namesort) cmp lc($b->artist->namesort)} @{$similarTracks};
		main::DEBUGLOG && $log->is_debug && $log->debug('Exec time = '.(time()-$started).' secs.');
	}
	return $similarTracks;
}

sub _filterSimilarTracksByLCSS {
	my ($sth, $curTitleNormalised, $curTitle, $similarityThreshold) = @_;
	my ($candidateTrackID, $trackTitle, $trackTitleSearch);
	my @similarTracks = ();

	$sth->bind_columns(undef, \$candidateTrackID, \$trackTitle, \$trackTitleSearch);
	while ($sth->fetch()) {
		if (defined($trackTitle)) {
			my $titleNormalised = normaliseTrackTitle($trackTitle);
			main::DEBUGLOG && $log->is_debug && $log->debug("-- currentTrackTitle normalised = $curTitleNormalised");
			main::DEBUGLOG && $log->is_debug && $log->debug("-- titleNormalised normalised = $titleNormalised");

			my @result = String::LCSS::lcss($curTitleNormalised, $titleNormalised);
			main::DEBUGLOG && $log->is_debug && $log->debug('-- Longest common substring = '.Data::Dump::dump($result[0]));

			if ($result[0] && length($result[0]) > 3) { # returns undef if longest common substring length is one char or less
				# similarity = max. length LCSS/track title
				my $similarity = max(length($result[0])/length($curTitleNormalised), length($result[0])/length($titleNormalised)) * 100;
				main::DEBUGLOG && $log->is_debug && $log->debug('--- longest common substring = '.$result[0]);
				main::INFOLOG && $log->is_info && $log->info('--- Similarity = '.Data::Dump::dump($similarity)."\t-- ".$trackTitleSearch);

				if ($similarity < $similarityThreshold) {
					main::INFOLOG && $log->is_info && $log->info(">>> Similarity $similarity < similarity threshold $similarityThreshold for track title '$trackTitle' and current track title '$curTitle'");
				} else {
					main::INFOLOG && $log->is_info && $log->info("--- Similarity of track is above specified minimum value.");
					my $thisTrack = Slim::Schema->rs('Track')->find($candidateTrackID);
					push @similarTracks, $thisTrack;
				}
			} else {
				main::INFOLOG && $log->is_info && $log->info("--- Tracks don't have a common substring with the minimum length.");
				next;
			}
		}
	}
	return \@similarTracks;
}

sub normaliseTrackTitle {
	my $title = shift;
	return if !$title;
	$title =~ s/[\[\(].*?[\)\]]//g; # delete everything between brackets + parentheses
	$title =~ s/((bonus|deluxe|12-inch|live|extended|instrumental|edit|interlude|alt\.|alternate|alternative|album|single|ep|maxi)+[ -]*(version|remix|mix|take|track))//ig; # delete some common words
	$title = uc(Slim::Utils::Text::ignoreCase($title, 1));
	return $title;
}

sub getRatingTextLine {
	my $rating100ScaleValue = shift;
	my $nobreakspace = HTML::Entities::decode_entities('&#xa0;');
	my $displayratingchar = preferences('plugin.ratingslight')->get('displayratingchar') // 0; # 0 = common text star *, 1 = "blackstar"
	my $ratingchar = $displayratingchar ? HTML::Entities::decode_entities('&#x2605;') : ' *';
	my $fractionchar = HTML::Entities::decode_entities('&#xbd;'); # "vulgar fraction one half"
	my $text = '';

	if ($rating100ScaleValue > 0) {
		$rating100ScaleValue = int(($rating100ScaleValue + 5)/10) * 10;
		my $detecthalfstars = ($rating100ScaleValue % 20 == 10) ? 1 : 0;
		my $ratingstars = int($rating100ScaleValue / 20);

		if ($detecthalfstars == 1) {
			if ($displayratingchar) {
				$text = ($ratingchar x $ratingstars).$fractionchar;
			} else {
				$text = ($ratingchar x $ratingstars).' '.$fractionchar;
			}
		} else {
			$text = ($ratingchar x $ratingstars);
		}

		if ($displayratingchar) {
			my $sepchar = HTML::Entities::decode_entities('&#x2022;'); # "bullet"
			$text = $nobreakspace.$sepchar.$nobreakspace.$text;
		} else {
			$text = $nobreakspace.'('.$text.$nobreakspace.')';
		}
	}
	return $text;
}


# backup / restore settings (prefs & selective tp stats only)
sub createBackup {
	if ($prefs->get('status_backuprestore')) {
		$log->warn('A backup or restore is already in progress, please wait for it to finish');
		return 0;
	}
	if (Slim::Music::Import->stillScanning) {
		$log->warn('Cannot create a backup while a library scan is in progress');
		return 0;
	}

	my $backupFolder = $prefs->get('backupoutputfolder');
	return 0 unless $backupFolder && -d $backupFolder;

	$prefs->set('status_backuprestore', 1);
	$prefs->set('backuprestoreprogresspercentage', 0);
	$prefs->set('backuprestoreresult', 0);
	$bkpErrors = 0;
	$bkpStarted = time();

	my $prefsDir = Slim::Utils::Prefs::dir() || Slim::Utils::OSDetect::dirsFor('prefs');
	main::DEBUGLOG && $log->is_debug && $log->debug('prefsDir = '.Data::Dump::dump($prefsDir));
	my $pluginPrefsDir = catdir($prefsDir, 'plugin');

	$bkpZip = Archive::Zip->new();

	for my $rootPrefsFile (_prefsFilesIn($prefsDir)) {
		next unless -f $rootPrefsFile;
		my (undef, undef, $fileName) = splitpath($rootPrefsFile);
		_addPrefsFileToZip($rootPrefsFile, $fileName);
	}

	for my $pluginPrefsFile (_prefsFilesIn($pluginPrefsDir)) {
		next unless -f $pluginPrefsFile;
		my (undef, undef, $fileName) = splitpath($pluginPrefsFile);
		# zip entry names always use forward slashes, regardless of OS
		_addPrefsFileToZip($pluginPrefsFile, "plugin/$fileName");
	}

	$bkpTempDir = tempdir(CLEANUP => 1);
	$bkpFile = catfile($backupFolder, 'PotPourri_backup_' . strftime('%Y%m%d_%H%M%S', localtime) . '.zip');

	_initTracksPersistentBackup();

	return 1;
}

sub _addPrefsFileToZip {
	my ($sourcePath, $zipEntryName) = @_;

	my $fileContent = eval {
		local $/;
		open(my $fh, '<:raw', $sourcePath) or die "$!";
		my $content = <$fh>;
		close $fh;
		$content;
	};
	if ($@ || !defined $fileContent) {
		$log->error("Could not read $sourcePath for backup archive - skipping it: " . ($@ || 'empty file'));
		return;
	}

	unless ($bkpZip->addString($fileContent, $zipEntryName)) {
		$log->error("Could not add $sourcePath to backup archive - skipping it");
	}
}

sub _initTracksPersistentBackup {
	my $dbh = Slim::Schema->dbh;
	my ($trackURL, $trackURLmd5, $added, $playCount, $lastPlayed, $remote, $trackMBID);

	@bkpPersistentTracks = ();
	my $sth = $dbh->prepare("select tracks_persistent.url, tracks_persistent.urlmd5, tracks_persistent.added, tracks_persistent.playCount, tracks_persistent.lastPlayed, tracks.remote, tracks_persistent.musicbrainz_id from tracks_persistent left join tracks on tracks.urlmd5 = tracks_persistent.urlmd5 where tracks_persistent.added is not null or tracks_persistent.playCount is not null or tracks_persistent.lastPlayed is not null");
	eval {
		$sth->execute();
		$sth->bind_columns(undef, \$trackURL, \$trackURLmd5, \$added, \$playCount, \$lastPlayed, \$remote, \$trackMBID);
		while ($sth->fetch()) {
			push (@bkpPersistentTracks, {'url' => $trackURL, 'urlmd5' => $trackURLmd5, 'added' => $added, 'playcount' => $playCount, 'lastplayed' => $lastPlayed, 'remote' => $remote, 'musicbrainzid' => $trackMBID});
		}
	};
	if ($@) {
		$log->error("Database error while reading tracks_persistent for backup: $@");
		$bkpErrors++;
		_finishBackup(0);
		return;
	}
	$sth->finish();

	$bkpTotalTrackCount = scalar(@bkpPersistentTracks);
	$bkpProcessedTrackCount = 0;

	unless ($bkpTotalTrackCount) {
		main::INFOLOG && $log->is_info && $log->info('No added/playCount/lastPlayed values found in tracks_persistent - nothing to back up');
		_finishBackup(0);
		return;
	}

	my $filename = catfile($bkpTempDir, 'trackspersistent_selectivestats.xml');
	$bkpOutput = FileHandle->new($filename, '>:utf8') or do {
		$log->error("Could not open $filename for writing");
		$bkpErrors++;
		_finishBackup(0);
		return;
	};

	print $bkpOutput "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n";
	print $bkpOutput "<!-- PotPourri backup of selected tracks_persistent values for ".$bkpTotalTrackCount.($bkpTotalTrackCount == 1 ? " track" : " tracks")." -->\n";
	print $bkpOutput "<TracksPersistentSelectiveStats>\n";
	print $bkpOutput "\t<trackcount>".$bkpTotalTrackCount."</trackcount>\n";

	main::INFOLOG && $log->is_info && $log->info('Starting tracks_persistent backup export for '.$bkpTotalTrackCount.' tracks');
	Slim::Utils::Scheduler::add_task(\&_bkpScanFunction);
}

sub _bkpScanFunction {
	for (my $i = 0; $i < 500 && @bkpPersistentTracks; $i++) {
		my $persistentTrack = shift(@bkpPersistentTracks);
		my $remoteFlag = defined($persistentTrack->{'remote'}) ? $persistentTrack->{'remote'} : 0;
		my $relFilePath = ($remoteFlag == 0) ? getRelFilePath($persistentTrack->{'url'}) : '';

		eval {
			print $bkpOutput "\t<track>\n";
			print $bkpOutput "\t\t<url>".escape($persistentTrack->{'url'})."</url>\n";
			print $bkpOutput "\t\t<urlmd5>".$persistentTrack->{'urlmd5'}."</urlmd5>\n";
			print $bkpOutput "\t\t<relurl>".($relFilePath ? escape($relFilePath) : '')."</relurl>\n";
			print $bkpOutput "\t\t<remote>".$remoteFlag."</remote>\n";
			print $bkpOutput "\t\t<added>".(defined($persistentTrack->{'added'}) ? $persistentTrack->{'added'} : '')."</added>\n";
			print $bkpOutput "\t\t<playcount>".(defined($persistentTrack->{'playcount'}) ? $persistentTrack->{'playcount'} : '')."</playcount>\n";
			print $bkpOutput "\t\t<lastplayed>".(defined($persistentTrack->{'lastplayed'}) ? $persistentTrack->{'lastplayed'} : '')."</lastplayed>\n";
			print $bkpOutput "\t\t<musicbrainzid>".($persistentTrack->{'musicbrainzid'} || '')."</musicbrainzid>\n";
			print $bkpOutput "\t</track>\n";
		};
		if ($@) {
			$log->error("Error writing track to backup file: $@");
			$bkpErrors++;
		}

		$bkpProcessedTrackCount++;
	}

	if ($bkpTotalTrackCount) {
		$prefs->set('backuprestoreprogresspercentage', sprintf("%.0f", ($bkpProcessedTrackCount / $bkpTotalTrackCount) * 100));
	}

	return 1 if @bkpPersistentTracks;

	print $bkpOutput "</TracksPersistentSelectiveStats>\n";
	close $bkpOutput;
	$bkpOutput = undef;

	_finishBackup(1);
	return 0;
}

sub _finishBackup {
	my $addTracksPersistentFile = shift;

	if ($addTracksPersistentFile) {
		unless ($bkpZip->addFile(catfile($bkpTempDir, 'trackspersistent_selectivestats.xml'), 'trackspersistent_selectivestats.xml')) {
			$log->error("Could not add tracks_persistent backup data to backup archive - skipping it");
			$bkpErrors++;
		}
	}

	if ($bkpZip->writeToFileNamed($bkpFile) != AZ_OK) {
		$log->error("Could not write backup archive to $bkpFile");
		$bkpErrors++;
	} else {
		main::INFOLOG && $log->is_info && $log->info('Backup archive created: '.$bkpFile.' after '.(time() - $bkpStarted).' seconds');
	}

	$prefs->set('backuprestoreresult', $bkpErrors > 0 ? 2 : 1);
	$prefs->set('backuprestoreprogresspercentage', 100);

	$bkpZip = undef;
	$bkpOutput = undef;
	@bkpPersistentTracks = ();

	$prefs->set('status_backuprestore', 0);
}

sub _prefsFilesIn {
	my $dir = shift;
	return () unless -d $dir;
	opendir(my $dh, $dir) or return ();
	my @files = map { catfile($dir, $_) } grep { /\.prefs$/i } readdir($dh);
	closedir($dh);
	return @files;
}

sub _isJunkZipEntry {
	my $fileName = shift;
	return 1 if $fileName =~ m{(?:^|/)__MACOSX/};
	return 1 if $fileName =~ m{/$};
	my @parts = split(m{/}, $fileName);
	my $baseName = $parts[-1];
	return 1 if !defined($baseName) || $baseName eq '';
	return 1 if $baseName =~ /^\._/ || $baseName =~ /^(?:\.DS_Store|Thumbs\.db|desktop\.ini)$/i;
	return 0;
}

sub _prefsNamespaceForZipEntry {
	my $fileName = shift;
	my @parts = split(m{/}, $fileName);
	my $baseName = $parts[-1];
	return undef unless defined($baseName) && $baseName =~ /^(.+)\.prefs$/i;
	my $prefsName = $1;
	return (@parts >= 2 && $parts[-2] eq 'plugin') ? "plugin.$prefsName" : $prefsName;
}

sub listBackupContents {
	my $zipFile = shift;
	return [] unless $zipFile && -f $zipFile;

	my $zip = Archive::Zip->new();
	if ($zip->read($zipFile) != AZ_OK) {
		$log->error("Could not read backup archive $zipFile");
		return [];
	}

	my @contents;
	for my $member ($zip->members) {
		my $fileName = $member->fileName;
		next if _isJunkZipEntry($fileName);

		my @parts = split(m{/}, $fileName);
		my $baseName = $parts[-1];

		if ($baseName eq 'trackspersistent_selectivestats.xml') {
			push @contents, { namespace => 'dateadded', label => string('PLUGIN_POTPOURRI_SETTINGS_RESTORE_DATEADDED_LABEL'), filename => $fileName };
			push @contents, { namespace => 'playcountlastplayed', label => string('PLUGIN_POTPOURRI_SETTINGS_RESTORE_PLAYCOUNTLASTPLAYED_LABEL'), filename => $fileName };
			next;
		}

		my $namespace = _prefsNamespaceForZipEntry($fileName);
		next unless defined $namespace;
		push @contents, { namespace => $namespace, filename => $fileName };
	}

	return [ sort { $a->{'namespace'} cmp $b->{'namespace'} } @contents ];
}

sub _requeuePendingRescanAfterRestart {
	return unless $prefs->get('restorependingrescan');

	$prefs->set('restorependingrescan', 0);
	my $request = Slim::Control::Request->new(undef, ['wipecache']);
	Slim::Music::Import->queueScanTask($request);
	main::INFOLOG && $log->is_info && $log->info('Re-queued rescan request after restart, following a preferences restore');
}

sub restoreFromBackup {
	my $selectedNamespaces = shift;

	unless ($selectedNamespaces && %{$selectedNamespaces}) {
		main::DEBUGLOG && $log->is_debug && $log->debug('restoreFromBackup called with no namespaces selected - nothing to do');
		return (0, 0);
	}

	if ($prefs->get('status_backuprestore')) {
		$log->warn('A backup or restore is already in progress, please wait for it to finish');
		return (0, 0);
	}
	if (Slim::Music::Import->stillScanning) {
		$log->warn('Cannot restore from backup while a library scan is in progress');
		return (0, 0);
	}

	my $restoreFile = $prefs->get('restorefile');
	return (0, 0) unless $restoreFile && -f $restoreFile;

	my $zip = Archive::Zip->new();
	if ($zip->read($restoreFile) != AZ_OK) {
		$log->error("Could not read backup archive $restoreFile");
		return (0, 0);
	}

	$prefs->set('status_backuprestore', 2);

	my $skipPrefs = _parseRestoreSkipPrefs($prefs->get('restoreskipprefs'));
	my $tempDir = tempdir(CLEANUP => 1);

	# queue any rescan/wipeCache triggered by restoring media-related server prefs
	# display message and let user trigger rescan manually after restarting
	Slim::Music::Import->doQueueScanTasks(1);

	for my $member ($zip->members) {
		my $fileName = $member->fileName;
		next if _isJunkZipEntry($fileName);

		my $namespace = _prefsNamespaceForZipEntry($fileName);
		next unless defined $namespace;

		next if $selectedNamespaces && !$selectedNamespaces->{$namespace};

		my $tempFile = catfile($tempDir, 'restore.prefs');
		if ($member->extractToFileNamed($tempFile) != AZ_OK) {
			$log->error("Could not extract $fileName from backup archive");
			next;
		}

		my $data = eval { LoadFile($tempFile) };
		unlink $tempFile;

		if ($@ || ref $data ne 'HASH') {
			$log->error("Could not parse $fileName from backup archive: " . ($@ || 'invalid data'));
			next;
		}

		my $namespacePrefs = preferences($namespace);
		for my $key (keys %{$data}) {
			next if $key =~ /^_/;
			next if $namespace eq 'plugin.potpourri' && $key =~ /^(?:status_backuprestore|backuprestoreresult|backuprestoreprogresspercentage|restoreskipprefs)$/;
			next if $skipPrefs->{$namespace}{$key};
			my $newValue = $data->{$key};
			my $oldValue = $namespacePrefs->get($key);
			# skip unchanged values. I seems Base::set() only short-circuits for scalars, not for array/hash refs.
			# this way we prevent restored list/hash prefs (e.g. media folders) from firing its onChange callbacks even if the value hasn't actually changed
			next if Data::Dump::dump($oldValue) eq Data::Dump::dump($newValue);
			$namespacePrefs->set($key, $newValue);
		}
		main::INFOLOG && $log->is_info && $log->info("Restored preferences for namespace $namespace from backup");
	}

	if (Slim::Music::Import->hasScanTask()) {
		$prefs->set('restorependingrescan', 1);
		Slim::Music::Import->clearScanQueue;
	}
	my $restoreDateAdded = $selectedNamespaces && $selectedNamespaces->{'dateadded'} ? 1 : 0;
	my $restorePlayCountLastPlayed = $selectedNamespaces && $selectedNamespaces->{'playcountlastplayed'} ? 1 : 0;

	if ($restoreDateAdded || $restorePlayCountLastPlayed) {
		my $xmlMember;
		for my $member ($zip->members) {
			my $fileName = $member->fileName;
			next if _isJunkZipEntry($fileName);
			my @parts = split(m{/}, $fileName);
			if ($parts[-1] eq 'trackspersistent_selectivestats.xml') {
				$xmlMember = $member;
				last;
			}
		}
		if ($xmlMember) {
			my $xmlTempFile = catfile($tempDir, 'trackspersistent_selectivestats.xml');
			if ($xmlMember->extractToFileNamed($xmlTempFile) == AZ_OK) {
				_initTracksPersistentRestore($xmlTempFile, $restoreDateAdded, $restorePlayCountLastPlayed);
			} else {
				$log->error("Could not extract trackspersistent_selectivestats.xml from backup archive");
				_finishRestore(2);
			}
		} else {
			$log->error("Selected trackspersistent restore, but trackspersistent_selectivestats.xml is missing from the backup archive");
			_finishRestore(2);
		}
	} else {
		_finishRestore($prefs->get('restorependingrescan') ? 3 : 1);
	}

	main::DEBUGLOG && $log->is_debug && $log->debug('restoreDateAdded='.$restoreDateAdded.' ## restorePlayCountLastPlayed='.$restorePlayCountLastPlayed.' ## status_backuprestore='.$prefs->get('status_backuprestore'));
	return (1, $prefs->get('restorependingrescan'));
}

sub _parseRestoreSkipPrefs {
	my $raw = shift;
	my %skip;
	return \%skip unless $raw;

	for my $entry (split(/,/, $raw)) {
		$entry =~ s/^\s+|\s+$//g;
		next unless $entry;

		my ($namespace, $key) = split(/:/, $entry, 2);
		if (!defined($key) || $namespace eq '' || $key eq '') {
			$log->warn("Ignoring invalid restore skip entry '$entry' - expected format is 'namespace:prefname'");
			next;
		}

		$skip{$namespace}{$key} = 1;
	}

	return \%skip;
}

sub _getTracksPersistentBackupTrackCount {
	my $xmlFile = shift;
	my $count;

	open(my $fh, '<', $xmlFile) or return 0;
	for (1..15) {
		my $line = <$fh>;
		last unless defined $line;
		if ($line =~ /<trackcount>(\d+)<\/trackcount>/) {
			$count = $1;
			last;
		}
	}
	close($fh);

	if (!defined $count) {
		main::DEBUGLOG && $log->is_debug && $log->debug('No trackcount element found in backup file - falling back to counting <track> occurrences (older backup format)');
		open(my $fh2, '<', $xmlFile) or return 0;
		$count = 0;
		while (my $line = <$fh2>) {
			my $matches = () = $line =~ /<track>/g;
			$count += $matches;
		}
		close($fh2);
	}

	return $count || 0;
}

sub _initTracksPersistentRestore {
	my ($xmlFile, $restoreDateAdded, $restorePlayCountLastPlayed) = @_;

	$tpRestoreFile = $xmlFile;
	$tpRestoreDateAdded = $restoreDateAdded;
	$tpRestorePlayCountLastPlayed = $restorePlayCountLastPlayed;
	$tpTotalTrackCount = _getTracksPersistentBackupTrackCount($xmlFile);
	$tpProcessedTrackCount = 0;
	$tpRestoreErrors = 0;

	if (defined($tpBackupParserNB)) {
		eval { $tpBackupParserNB->parse_done };
		$tpBackupParserNB = undef;
	}
	$tpBackupParser = XML::Parser->new(
		'ErrorContext' => 2,
		'ProtocolEncoding' => 'UTF-8',
		'NoExpand' => 1,
		'NoLWP' => 1,
		'Handlers' => {
			'Start' => \&_tpHandleStartElement,
			'Char' => \&_tpHandleCharElement,
			'End' => \&_tpHandleEndElement,
		},
	);

	$tpRestoreFH = undef;
	$tpOpened = 0;
	$tpRestoreCount = 0;
	$tpRestoreStarted = time();

	main::INFOLOG && $log->is_info && $log->info('Starting tracks_persistent restore from backup file');
	Slim::Utils::Scheduler::add_task(\&_tpRestoreScanFunction);
}

sub _tpRestoreScanFunction {
	if ($tpOpened != 1) {
		open($tpRestoreFH, '<', $tpRestoreFile) || do {
			$log->error("Could not open tracks_persistent backup file: $tpRestoreFile");
			_finishRestore(2);
			return 0;
		};
		$tpOpened = 1;
		$tpInTrack = 0;
		$tpInValue = 0;
		%tpRestoreItem = ();
		$tpCurrentKey = undef;

		if (defined $tpBackupParser) {
			$tpBackupParserNB = $tpBackupParser->parse_start();
		} else {
			$log->warn('No tpBackupParser was defined!');
		}
	}

	if (defined $tpBackupParserNB) {
		local $/ = '>';
		my $line;

		for (my $i = 0; $i < 25;) {
			my $singleLine = <$tpRestoreFH>;
			if (defined($singleLine)) {
				$line .= $singleLine;
				if ($singleLine =~ /(<\/track>)$/) {
					$i++;
				}
			} else {
				last;
			}
		}
		$line //= '';
		$line =~ s/&#(\d*);/escape(chr($1))/ge;
		$tpBackupParserNB->parse_more($line);
		return defined($tpBackupParserNB) ? 1 : 0;
	}

	$log->warn('No tpBackupParserNB defined!');
	_finishRestore(2);
	return 0;
}

sub _finishRestore {
	my $result = shift; # 1 = success, 2 = error, 3 = success, requires rescan (mapped to global result codes below)
	my $resultCode = { 1 => 3, 2 => 4, 3 => 5 }->{$result};
	$prefs->set('backuprestoreresult', $resultCode);
	$prefs->set('backuprestoreprogresspercentage', 100);
	$prefs->set('status_backuprestore', 0);
}

sub _tpDoneScanning {
	if (defined $tpBackupParserNB) {
		eval { $tpBackupParserNB->parse_done };
	}

	$tpBackupParserNB = undef;
	$tpBackupParser = undef;
	$tpOpened = 0;
	close($tpRestoreFH) if $tpRestoreFH;
	$tpRestoreFH = undef;

	main::INFOLOG && $log->is_info && $log->info('tracks_persistent restore completed after '.(time() - $tpRestoreStarted).' seconds. Restored '.$tpRestoreCount.($tpRestoreCount == 1 ? ' track.' : ' tracks.'));
	_finishRestore($tpRestoreErrors > 0 ? 2 : ($prefs->get('restorependingrescan') ? 3 : 1));
}

sub _tpHandleStartElement {
	my ($p, $element) = @_;

	if ($tpInTrack) {
		$tpCurrentKey = $element;
		$tpInValue = 1;
	}
	if ($element eq 'track') {
		$tpInTrack = 1;
	}
}

sub _tpHandleCharElement {
	my ($p, $value) = @_;

	if ($tpInValue && $tpCurrentKey) {
		$tpRestoreItem{$tpCurrentKey} = $value;
	}
}

sub _tpHandleEndElement {
	my ($p, $element) = @_;
	$tpInValue = 0;

	if ($tpInTrack && $element eq 'track') {
		$tpInTrack = 0;

		my $curTrack = \%tpRestoreItem;
		my $trackURL;
		my $fullTrackURL = $curTrack->{'url'};
		my $backupTrackURLmd5 = $curTrack->{'urlmd5'};
		my $isRemote = $curTrack->{'remote'};
		my $relTrackURL = $curTrack->{'relurl'};
		my $trackMBID = $curTrack->{'musicbrainzid'};

		$fullTrackURL = Encode::decode('utf8', unescape($fullTrackURL));
		$relTrackURL = Encode::decode('utf8', unescape($relTrackURL)) if $relTrackURL;

		if ($isRemote && $isRemote == 1) {
			$trackURL = $fullTrackURL;
		} else {
			my $fullTrackPath = pathForItem($fullTrackURL);
			if ($fullTrackPath && -f $fullTrackPath) {
				$trackURL = $fullTrackURL;
			} elsif ($relTrackURL) {
				my $lmsmusicdirs = getMusicDirs();
				foreach (@{$lmsmusicdirs}) {
					my $dirSep = File::Spec->canonpath("/");
					my $mediaDirURL = Slim::Utils::Misc::fileURLFromPath($_.$dirSep);
					my $newFullTrackURL = $mediaDirURL.$relTrackURL;
					my $newFullTrackPath = pathForItem($newFullTrackURL);
					if (-f $newFullTrackPath) {
						$trackURL = Slim::Utils::Misc::fileURLFromPath($newFullTrackURL);
						last;
					}
				}
			}
		}

		if (!$trackURL && !$backupTrackURLmd5 && !$trackMBID) {
			$log->warn("No valid urlmd5, url or musicbrainz id for this track - can't restore values. Backup URL was: ".Data::Dump::dump($fullTrackURL));
		} else {
			my (@setParts, @bindVals);
			if ($tpRestoreDateAdded) {
				my $added = (!defined($curTrack->{'added'}) || $curTrack->{'added'} eq '' || $curTrack->{'added'} !~ /^\d+$/) ? undef : $curTrack->{'added'} + 0;
				push @setParts, 'added = ?';
				push @bindVals, $added;
			}
			if ($tpRestorePlayCountLastPlayed) {
				my $playCount = (!defined($curTrack->{'playcount'}) || $curTrack->{'playcount'} eq '' || $curTrack->{'playcount'} !~ /^\d+$/) ? undef : $curTrack->{'playcount'} + 0;
				my $lastPlayed = (!defined($curTrack->{'lastplayed'}) || $curTrack->{'lastplayed'} eq '' || $curTrack->{'lastplayed'} !~ /^\d+$/) ? undef : $curTrack->{'lastplayed'} + 0;
				push @setParts, 'playCount = ?', 'lastPlayed = ?';
				push @bindVals, $playCount, $lastPlayed;
			}

			if (@setParts) {
				my $setClause = 'set '.join(', ', @setParts);
				my $dbh = Slim::Schema->dbh;

				my @urlmd5Candidates;
				push @urlmd5Candidates, $backupTrackURLmd5 if $backupTrackURLmd5;
				if ($trackURL) {
					my $freshUrlmd5 = md5_hex($trackURL);
					push @urlmd5Candidates, $freshUrlmd5 unless grep { $_ eq $freshUrlmd5 } @urlmd5Candidates;
					if (Slim::Utils::Misc->can('safe_md5_hex')) {
						my $freshSafeUrlmd5 = Slim::Utils::Misc::safe_md5_hex($trackURL);
						push @urlmd5Candidates, $freshSafeUrlmd5 unless grep { $_ eq $freshSafeUrlmd5 } @urlmd5Candidates;
					}
				}

				my $updated = 0;
				for my $urlmd5Candidate (@urlmd5Candidates) {
					if ($urlmd5Candidate !~ /^[a-f0-9]{32}$/i) {
						$log->error("Invalid urlmd5 in backup file, skipping candidate: $urlmd5Candidate");
						next;
					}
					my $rowsAffected = eval { $dbh->do("update tracks_persistent $setClause where urlmd5 = ?", undef, @bindVals, $urlmd5Candidate) };
					if ($@) {
						$log->error("Database error: $@");
						$tpRestoreErrors++;
						next;
					}
					if ($rowsAffected && $rowsAffected > 0) {
						$updated = 1;
						$tpRestoreCount++;
						last;
					}
				}

				if (!$updated && $trackMBID) {
					if ($trackMBID !~ /^[a-zA-Z0-9\-]+$/) {
						$log->error("Invalid MBID in backup file, skipping track: $trackMBID");
					} else {
						my $rowsAffected = eval { $dbh->do("update tracks_persistent $setClause where musicbrainz_id = ?", undef, @bindVals, $trackMBID) };
						if ($@) {
							$log->error("Database error: $@");
							$tpRestoreErrors++;
						} elsif ($rowsAffected && $rowsAffected > 0) {
							$tpRestoreCount++;
						}
					}
				}
			}
		}
		$tpProcessedTrackCount++;
		if ($tpTotalTrackCount) {
			$prefs->set('backuprestoreprogresspercentage', sprintf("%.0f", ($tpProcessedTrackCount / $tpTotalTrackCount) * 100));
		}
		%tpRestoreItem = ();
	}
	if ($element eq 'TracksPersistentSelectiveStats') {
		_tpDoneScanning();
		return 0;
	}
}


# misc
sub powerOffClientsScheduler {
	main::DEBUGLOG && $log->is_debug && $log->debug('Killing existing timers for scheduled power-off');
	Slim::Utils::Timers::killOneTimer(undef, \&powerOffClientsScheduler);
	my $enableScheduledClientsPowerOff = $prefs->get('enablescheduledclientspoweroff');
	if ($enableScheduledClientsPowerOff) {
		my ($powerOffTimeUnparsed, $powerOffTime);
		$powerOffTimeUnparsed = $powerOffTime = $prefs->get('powerofftime');

		if (defined($powerOffTime) && $powerOffTime ne '') {
			my $time = 0;
			$powerOffTime =~ s{
				^(0?[0-9]|1[0-9]|2[0-3]):([0-5][0-9])\s*(P|PM|A|AM)?$
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
				main::INFOLOG && $log->is_info && $log->info('Current time '.parse_duration($currenttime).' = scheduled power-off time '.$powerOffTimeUnparsed.'. Powering off all players now.');
				foreach my $client (Slim::Player::Client::clients()) {
					if ($client->power()) {
						$client->stop() if $client->isPlaying();
						$client->power(0);
					}
				}
				Slim::Utils::Timers::setTimer(undef, time() + 120, \&powerOffClientsScheduler);
			} else {
				my $timeleft = $powerOffTime - $currenttime;
				$timeleft = $timeleft + 24 * 60 * 60 if $timeleft < 0; # it's past powerOffTime -> schedule for same time tomorrow
				main::INFOLOG && $log->is_info && $log->info(parse_duration($timeleft)." until next scheduled power-off at ".$powerOffTimeUnparsed);
				Slim::Utils::Timers::setTimer(undef, time() + $timeleft, \&powerOffClientsScheduler);
			}
		} else {
			$log->warn('powerOffTime = not defined or empty string');
		}
	}
}

sub initPLtoplevellink {
	main::DEBUGLOG && $log->is_debug && $log->debug('Started initializing playlist toplevel link.');
	# deregister item first
	Slim::Menu::BrowseLibrary->deregisterNode('PTP_HOMEMENU_TOPLEVEL_LINKEDPLAYLIST');

	# link to playlist in home menu
	my $toplevelplaylistname = $prefs->get('toplevelplaylistname') || 'none';
	main::DEBUGLOG && $log->is_debug && $log->debug('toplevelplaylistname = '.$toplevelplaylistname);
	if ($toplevelplaylistname ne 'none') {
		my $toplevelplaylistID = getPlaylistIDforName($toplevelplaylistname);
		main::DEBUGLOG && $log->is_debug && $log->debug('name of linked playlist (ID: '.$toplevelplaylistID.') = '.$toplevelplaylistname);

		Slim::Menu::BrowseLibrary->registerNode({
			type => 'link',
			name => 'PLUGIN_POTPOURRI_TOPLEVEL_LINKEDPLAYLIST_NAME',
			params => {'playlist_id' => $toplevelplaylistID},
			feed => \&Slim::Menu::BrowseLibrary::_playlistTracks,
			icon => 'plugins/PotPourri/html/images/browsemenupfoldericon.png',
			jiveIcon => 'plugins/PotPourri/html/images/browsemenupfoldericon.png',
			condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
			id => 'PTP_HOMEMENU_TOPLEVEL_LINKEDPLAYLIST',
			weight => 79,
			cache => 0,
		});
	}
	main::DEBUGLOG && $log->is_debug && $log->debug('Finished initializing playlist toplevel link.');
}

sub purgeDeadTracksPersistent {
	my $dbh = Slim::Schema->dbh;
	main::DEBUGLOG && $log->is_debug && $log->debug('Removing remove dead tracks from the LMS tracks_persistent table whose file URL has no match in the current LMS tracks table.');

	my $sqlstatement = "delete from tracks_persistent where urlmd5 not in (select urlmd5 from tracks where tracks.urlmd5 = tracks_persistent.urlmd5)";
	eval {$dbh->do($sqlstatement)};
	if ($@) {
		$log->error("Database error: $@");
	}
	main::DEBUGLOG && $log->is_debug && $log->debug('Finished removing dead tracks from tracks_persistent.');
}

sub APCqueryBatch {
	my ($trackURLmd5s, $queryType) = @_;
	my %result;
	return \%result unless $trackURLmd5s && @{$trackURLmd5s} && $queryType;
	my $dbh = Slim::Schema->dbh;
	my $sth = $dbh->prepare("select ifnull($queryType, 0) from alternativeplaycount where urlmd5 = ?");
	unless ($sth) {
		$log->error("Could not prepare APC query for $queryType: ".$dbh->errstr);
		return \%result;
	}
	for my $trackURLmd5 (@{$trackURLmd5s}) {
		my $returnVal;
		eval {
			$sth->execute($trackURLmd5);
			$sth->bind_columns(undef, \$returnVal);
			$sth->fetch();
		};
		if ($@) {
			$log->error("Database error: $@");
			next;
		}
		$result{$trackURLmd5} = $returnVal;
		main::DEBUGLOG && $log->is_debug && $log->debug('Current APC '.$queryType.' for trackurlmd5 ('.$trackURLmd5.') = '.$returnVal);
	}
	$sth->finish();
	return \%result;
}

sub getTrackIdForContextMenu {
	my ($client, $url, $track) = @_;
	if ($track->id) {
		return {
			type => 'text',
			name => 'Track ID: '.$track->id,
			itemvalue => $track->id,
			itemid => $track->id,
		};
	} else {
		return;
	}
}

sub displayMessage {
	my ($client, $messageType) = @_;

	my $message = '';
	if ($messageType == 1) {
		$message = string('PLUGIN_POTPOURRI_PL_SORTORDER_FAILED');
	} else {
		$message = string('PLUGIN_POTPOURRI_PL_SORTORDER_SUCCESS');
	}

	if (Slim::Buttons::Common::mode($client) !~ /^SCREENSAVER./) {
		$client->showBriefly({'line' => [string('PLUGIN_POTPOURRI'), $message]}, 5);
	}
	if ($material_enabled) {
		Slim::Control::Request::executeRequest(undef, ['material-skin', 'send-notif', 'type:info', 'msg:'.$message, 'client:'.$client->id, 'timeout:5']);
	}
}

sub getPlaylistIDforName {
	my $playlistname = shift;
	my $queryresult = Slim::Control::Request::executeRequest(undef, ['playlists', 0, 1, 'search:'.$playlistname]);
	my $existsPL = $queryresult->getResult('count');
	my $playlistid;
	if ($existsPL > 0) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Playlist '".$playlistname."' exists.");
		my $PLloop = $queryresult->getResult('playlists_loop');
		foreach my $playlist (@{$PLloop}) {
			$playlistid = $playlist->{id};
		}
	return $playlistid || '' ;
	} else {
		$log->warn("Couldn't find selected playlist to link to.");
		return '';
	}
}

sub getMusicDirs {
	my $mediadirs = $serverPrefs->get('mediadirs');
	my $ignoreInAudioScan = $serverPrefs->get('ignoreInAudioScan');
	my $lmsmusicdirs = [];
	my %musicdircount;
	foreach my $thisdir (@{$mediadirs}, @{$ignoreInAudioScan}) {$musicdircount{$thisdir}++}
	foreach my $thisdir (keys %musicdircount) {
		if ($musicdircount{$thisdir} == 1) {
			push (@{$lmsmusicdirs}, $thisdir);
		}
	}
	return $lmsmusicdirs;
}

sub getRelFilePath {
	my $fullTrackURL = shift;
	my $relFilePath;
	my $lmsmusicdirs = getMusicDirs();
	main::DEBUGLOG && $log->is_debug && $log->debug('Valid LMS music dirs = '.Data::Dump::dump($lmsmusicdirs));

	foreach (@{$lmsmusicdirs}) {
		my $dirSep = File::Spec->canonpath("/");
		my $mediaDirPath = $_.$dirSep;
		my $fullTrackPath = Slim::Utils::Misc::pathFromFileURL($fullTrackURL);
		my $match = checkInFolder($fullTrackPath, $mediaDirPath);

		main::DEBUGLOG && $log->is_debug && $log->debug("Full file path \"$fullTrackPath\" is".($match == 1 ? "" : " NOT")." part of media dir \"".$mediaDirPath."\"");
		if ($match == 1) {
			$relFilePath = file($fullTrackPath)->relative($_);
			$relFilePath = Slim::Utils::Misc::fileURLFromPath($relFilePath);
			$relFilePath =~ s/^(file:)?\/+//isg;
			main::DEBUGLOG && $log->is_debug && $log->debug('Saving RELATIVE file path: '.$relFilePath);
			last;
		}
	}
	if (!$relFilePath) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Couldn't get relative file path for \"$fullTrackURL\".");
	}
	return $relFilePath;
}

sub checkInFolder {
	my $path = shift || return;
	my $checkdir = shift;

	$path = Slim::Utils::Misc::fixPath($path) || return 0;
	$path = Slim::Utils::Misc::pathFromFileURL($path) || return 0;
	main::DEBUGLOG && $log->is_debug && $log->debug('path = '.$path.' -- checkdir = '.$checkdir);

	if ($checkdir && $path =~ /^\Q$checkdir\E/) {
		return 1;
	} else {
		return 0;
	}
}

sub pathForItem {
	my $item = shift;
	if (Slim::Music::Info::isFileURL($item) && !Slim::Music::Info::isFragment($item)) {
		my $path = Slim::Utils::Misc::fixPath($item) || return 0;
		return Slim::Utils::Misc::pathFromFileURL($path);
	}
	return $item;
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
	} elsif ($arg =~ m/^([0\s]?[0-9]|1[0-9]|2[0-3]):([0-5][0-9])\s*(P|PM|A|AM)?$/isg) {
		return 1;
	}
	return 0;
}

sub trimStringLength {
	my ($thisString, $maxlength) = @_;
	if (defined $thisString && (length($thisString) > $maxlength)) {
		$thisString = substr($thisString, 0, $maxlength).'...';
	}
	return $thisString;
}

sub getDisplayName {'PLUGIN_POTPOURRI'}

*escape = \&URI::Escape::uri_escape_utf8;
*unescape = \&URI::Escape::uri_unescape;

1;
