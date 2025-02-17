PotPourri
====

A collection of various small [features](#features).
<br><br>
## Requirements

- LMS version >= 8.**4**
- LMS database = **SQLite**

<br>
<a href="https://github.com/AF-1/">⬅️ <b>Back to the list of all plugins</b></a>
<br><br>

**Use the** &nbsp; <img src="screenshots/menuicon.png" width="30"> &nbsp;**icon** (top right) to **jump directly to a specific section.**

<br><br>


## Features:
- **Change the track order of *saved static* playlists** (context menu) or **client playlists** (*App menu icon*). Multiple sort options available.

- Set a **power-on volume level for players** that's enforced when players are switched on.[^1] The (sub)menu is listed on the *LMS Settings > Player* page.

- Set a **time to turn off *all* players** each day. No more worries about idle players that you forgot to switch off.

- **Export static playlists** to playlist files with custom **file paths and file extensions**[^2].

- **Adjust album *release types*** based on keywords in the album title (e.g. [Single]).

- Use **(key)words** in your music files' <b><u>comment</u> tags</b> to add **extra information** to the **song details page** / context menu information or to define and display **custom title formats**[^3].

- Purge dead tracks from the *tracks_persistent* table.

- …
<br><br><br>


## Screenshots[^4] (of some features)

<img src="screenshots/ppt.gif" width="100%">
<br><br><br>


## Installation

**PotPourri** is available from the LMS plugin library: **LMS > Settings > Manage Plugins**.<br>

If you want to test a new patch that hasn't made it into a release version yet, you'll have to [install the plugin manually](https://github.com/AF-1/sobras/wiki/Manual-installation-of-LMS-plugins).
<br><br><br>


## Report a new issue

To report a new issue please file a GitHub [**issue report**](https://github.com/AF-1/lms-potpourri/issues/new/choose).<br><br>
If you use this plugin and like it, perhaps you could give it a :star: so that other users can discover it (in their News Feed). Thank you.
<br><br><br><br>

[^1]:based on parts of E. Koldinger's [**Reset Volume**](https://github.com/koldinger/ResetVolume)
[^2]:Files will be exported to the **LMS playlists folder** or alternatively to the **LMS preferences folder**.
[^3]:<b>Custom title formats</b> can be used to display a <i>short</i> string or a character on the <i>Now Playing screensaver</i> and the <i>Music Information plugin screensaver</i> or to append a string to the track title.
[^4]: The screenshots might not correspond to the UI of the latest release in every detail.
