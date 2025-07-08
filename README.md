PotPourri
====
![Min. LMS Version](https://img.shields.io/badge/dynamic/xml?url=https%3A%2F%2Fraw.githubusercontent.com%2FAF-1%2Fsobras%2Fmain%2Frepos%2Flms%2Fpublic.xml&query=%2F%2F*%5Blocal-name()%3D'plugin'%20and%20%40name%3D'PotPourri'%5D%2F%40minTarget&prefix=v&label=Min.%20LMS%20Version%20Required&color=darkgreen)<br>

A collection of various small [features](#features).

<br>
<a href="https://github.com/AF-1/">⬅️ <b>Back to the list of all plugins</b></a>
<br><br>

**Use the** &nbsp; <img src="screenshots/menuicon.png" width="30"> &nbsp;**icon** (top right) to **jump directly to a specific section.**

<br><br>


## Features:
- **Change the track order of *saved static* playlists** (context menu) or **client playlists** (*App menu icon*). Multiple sort options available.

- *Player Volume Settings* (on the `LMS Settings > Player` page):

   - Set a *power-on* volume level for players that's enforced when players are switched on.[^1]

   - *Lock* the volume level for a player or *set a max.* player volume.[^2]

- Set a **time to turn off *all* players** each day. No more worries about idle players that you forgot to switch off.

- **Export static playlists** to playlist files with custom **file paths and file extensions**[^3].

- **Adjust album *release types*** based on keywords in the album title (e.g. [Single]).

- Use **(key)words** in your music files' <b><u>comment</u> tags</b> to add **extra information** to the **song details page** / context menu information or to define and display **custom title formats**[^4].

- Purge dead tracks from the *tracks_persistent* table.

- …
<br><br><br>


## Screenshots[^5] (of some features)

<img src="screenshots/ppt.gif" width="100%">
<br><br><br>


## Installation

**PotPourri** is available from the LMS plugin library: `LMS > Settings > Manage Plugins`.<br>

If you want to test a new patch that hasn't made it into a release version yet, you'll have to [install the plugin manually](https://github.com/AF-1/sobras/wiki/Manual-installation-of-LMS-plugins).
<br><br><br><br>


## FAQ
<details><summary>»<b>I've set the player volume to be locked or capped (max. volume). When I change the volume, it is reset correctly but sometimes the player UI still displays the wrong  value.</b>«</summary><br><p>
That can happen occasionally if you click or press buttons a lot very fast. Or if the player volume is not reset using the UI, e.g. if you enable fixed or max. volume in the preferences settings and the current player volume needs to be reset right away to comply with the new restrictions.<br>Unfortunately, I cannot guarantee that the volume level is <i>always</i> displayed(!) correctly..<br>The important thing is that the <i>actual</i> volume level on the player itself is correct.</p></details><br>
<br><br>


## Report a new issue

To report a new issue please file a GitHub [**issue report**](https://github.com/AF-1/lms-potpourri/issues/new/choose).
<br><br><br>


## ⭐ Help others discover this project

If you find this project useful, giving it a <img src="screenshots/githubstar.png" width="20" height="20" alt="star" /> (top right of this page) is a great way to show your support and help others discover it. Thank you.
<br><br><br><br>

[^1]:based on parts of E. Koldinger's [**Reset Volume**](https://github.com/koldinger/ResetVolume)
[^2]:inspired by Peter Watkins' [**Volume Lock**](https://tuxreborn.netlify.app/slim/VolumeLock.html)
[^3]:Files will be exported to the **LMS playlists folder** or alternatively to the **LMS preferences folder**.
[^4]:<b>Custom title formats</b> can be used to display a <i>short</i> string or a character on the <i>Now Playing screensaver</i> and the <i>Music Information plugin screensaver</i> or to append a string to the track title.
[^5]: The screenshots might not correspond to the UI of the latest release in every detail.
