# Fedora post installation guide

Welcome to my personal Fedora post installation guide. In this particular document, I try to describe most of steps I do after a clean install of this awesome Linux distribution. Ideas and suggestions were collected from different sources, including [Fedy](http://folkswithhats.org/), and also from personal experience. Use this guide at your own risk and have fun with Fedora! :wink:

## Upgrade the entire system

First of all, let us update the entire system after a clean Fedora install. This procedure is highly recommended (if not a mandatory step), as a lot of potential bugs that could not be fixed for the distro release might already have a patch by now. Open the terminal and type:

```bash
$ sudo dnf upgrade --refresh -y
```

## Enable RPM Fusion

Fedora already has great applications available out of the box. As to enhance the experience, let us add the repositories for contributed packages ([RPM Fusion](http://rpmfusion.org/)). We can configure it in one command:

```bash
sudo dnf install \
https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
```

## Terminal with colours

I enjoy having colours in my terminal, although it is entirely optional. If you want to have a nice coloured terminal, create a file named `colours.sh` with the following content:

```bash
if [[ ! -z \$BASH ]]; then
 if [[ \$USER = "root" ]]; then
  PS1="\[\033[33m\][\[\033[m\]\[\033[31m\]\u@\h\[\033[m\] \[\033[33m\]\W\[\033[m\]\[\033[33m\]]\[\033[m\] # "
 elif [[ $(whoami) = "root" ]]; then
  PS1="\[\033[33m\][\[\033[m\]\[\033[31m\]\u@\h\[\033[m\] \[\033[33m\]\W\[\033[m\]\[\033[33m\]]\[\033[m\] # "
 else
  PS1="\[\033[36m\][\[\033[m\]\[\033[34m\]\u@\h\[\033[m\] \[\033[32m\]\W\[\033[m\]\[\033[36m\]]\[\033[m\] \$ "
 fi
fi
```

And move it to `/etc/profile.d/`:

```bash
$ sudo mv colours.sh /etc/profile.d/
```

There is no need to restart your entire session. Simply restart your terminal (or open a new tab) and have fun!

## Improve font rendering

Fedora has a great font support. I used to rely on an specific release of Freetype available in the contributed repositories, but this procedure became obsolete since Fedora 30. It is quite certain that you already have the default `freetype` package installed in your machine, so let us tweak our font configuration. In order to ease our setup, I highly suggest installing the Gnome Tweaks tool:

```bash
$ sudo dnf install gnome-tweaks
```

Now, open this tool we have just installed and set _subpixel antialising_ in the _Fonts_ section. Alternatively, we can use the terminal to adjust such things:

```bash
$ gsettings set org.gnome.settings-daemon.plugins.xsettings antialiasing "rgba"
$ gsettings set org.gnome.settings-daemon.plugins.xsettings hinting "slight"
```

You can tweak a lot of things, so your mileage can greatly vary. I usually restart my session, so changes can be applied accordingly.

## Useful packages

These are some packages I like to install in most of my Fedora machines. Use them at your own risk!

1. Lilypond and Frescobaldi for writing sheet music. The former is the actual engraver, the latter is a nice editor for such files.

    ```bash
    $ sudo dnf install lilypond frescobaldi
    ```

2. Timidity for playing MIDI files. I also included the corresponding multimedia codec for use in other applications.

    ```bash
    $ sudo dnf install timidity++ \
    gstreamer1-plugins-bad-free-fluidsynth
    ```

3. MPV as a multimedia player, and FFmpeg and Lame for conversion. I also set MPV as my default multimedia player in the system configuration.

    ```bash
    $ sudo dnf install mpv ffmpeg lame
    ```

4. Some useful command line archiving tools. Of course, `zip` and `tar` are already available out of the box, but it is quite convenient to have support for other archive formats, specially `rar` files.

    ```bash
    $ sudo dnf install p7zip p7zip-plugins unrar
    ```

5. Editors in general. Note that `vim`, `emacs` and `nano` are the typical command line editors. I included Leafpad as it is a very lightweight editor, and TeXworks as it is one of the nicest TeX editors out there.

    ```bash
    $ sudo dnf install vim emacs leafpad nano texworks
    ```

6. Graphic design editors and utilities. Inkscape and GIMP are graphical applications, while Potrace and ImageMagick are command line utilities.

    ```bash
    $ sudo dnf install inkscape gimp potrace ImageMagick
    ```

7. Backgrounds for the current release of Fedora. I highly recommend the abstract ones, as they look awesome!

    ```bash
    $ sudo dnf install f$(rpm -E %fedora)-backgrounds \
    f$(rpm -E %fedora)-backgrounds-base \
    f$(rpm -E %fedora)-backgrounds-gnome \
    f$(rpm -E %fedora)-backgrounds-animated \
    f$(rpm -E %fedora)-backgrounds-extras-base \
    f$(rpm -E %fedora)-backgrounds-extras-gnome
    ```

8. The latest Java virtual machine. Be mindful that the default Java commands might not resolve to this version, so make sure to update the symbolic links with the `update-alternatives` tool.

    ```bash
    $ sudo dnf install java-latest-openjdk \
    java-latest-openjdk-jmods \
    java-latest-openjdk-devel \
    java-latest-openjdk-headless
    ```

9. Other useful applications and tools. Make sure to read their descriptions before installing them in the wild. I would rather have only the packages I actually need on a daily basis.

    ```bash
    $ sudo dnf install thunderbird poedit ack \
    maven htop bleachbit axel zsh python3-ipython \
    rubygem-rake audacity-freeworld powerline \
    tmux byobu
    ```

## Editors

I like to recommend the [Janus](https://github.com/carlhuda/janus) distribution for `vim` users. To install it, open the terminal and run the following command:

```bash
$ curl -L https://bit.ly/janus-bootstrap | bash
```

The Janus distribution will be installed in your `$HOME/.vim` directory. After a proper install, I create a `.janus` directory in my `$HOME`:

```bash
$ mkdir ~/.janus
```

And populate it with the `vim` plugins I use:

```
$ cd ~/.janus
$ git clone https://github.com/godlygeek/tabular.git
$ git clone https://github.com/vim-airline/vim-airline.git
```

Once both distribution and plugins are in place, this is my `$HOME/.vimrc.before` configuration:

```vim
let g:tex_flavor = 'latex'
let g:airline_powerline_fonts = 0
let g:airline#extensions#tabline#enabled = 1
```

I like to recommend the [Spacemacs](https://github.com/syl20bnr/spacemacs) distribution for `emacs` users. To install it, open the terminal and run the following command:

```bash
$ git clone https://github.com/syl20bnr/spacemacs ~/.emacs.d
```

Now, just open Emacs and follow the instructions on screen. Spacemacs will be configured accordingly.

## Fortune cookies in the terminal

This is a very amusing feature to add to your terminal. First of all, we need to install `fortune-mod`:

```bash
$ sudo dnf install fortune-mod
```

Then add the following content to `~/.bashrc`:

```bash
if [ -f /usr/bin/fortune ]; then
    /usr/bin/fortune
    echo
fi
```

There is no need to restart your entire session. Simply restart your terminal (or open a new tab) and have fun!

## A fancy Z shell

A great enhancement to `zsh` is [Oh my `zsh`](https://github.com/robbyrussell/oh-my-zsh). I personally do not like the last part of the install script, as it changes your current shell. I usually prefer downloading the script:

```bash
$ wget https://raw.githubusercontent.com/robbyrussell/oh-my-zsh/master/tools/install.sh
```

Then I edit `install.sh` comment the parts I do not want. After the proper changes, we simply execute the following command:

```bash
$ sh install
```

## Install Snap

Snap can be installed on Fedora. Not exactly my cup of tea, but there are some interesting packages that can be easily deployed in the system through this method. Simply run the following command:

```
$ sudo dnf install snapd
```

If I recall correctly, Snap has three modes, and one of them, named _classic_, requires an extra step to be enabled. Personally, this mode defeats the idea of running applications inside a self-contained sandbox, but some applications seem to require it. Run the following command:

```bash
$ sudo ln -s /var/lib/snapd/snap /snap
```

At last, but not least, if you are interested in knowing more about Snap applications (or _snaps_, as they are called), install the Snap store, so these snaps can be more readily discovered. Run the following command:

```bash
$ sudo snap install snap-store
```

## Install and configure TeX Live

TeX Live is, in my humble opinion, the best TeX distribution out there. Let us get the install script from TUG and run:

```bash
$ wget http://mirror.ctan.org/systems/texlive/tlnet/install-tl-unx.tar.gz
$ tar xvzf install-tl-unx.tar.gz
$ cd install-tl-20*
$ sudo ./install-tl
```

After installing TeX Live, let us create a symbolic link:

```bash
$ sudo ln -s /usr/local/texlive/<year>/bin/<arch> /opt/texbin
```

Create a file named `texlive.sh` with the following content:

```bash
#!/bin/bash
pathmunge () {
    if ! echo $PATH | /bin/egrep -q "(^|:)$1($|:)" ; then
        if [ "$2" = "after" ] ; then
            PATH=$PATH:$1
        else
            PATH=$1:$PATH
        fi
    fi
}
pathmunge /opt/texbin
unset pathmunge
```

Then move it to `/etc/profile.d/`:

```bash
$ sudo mv texlive.sh /etc/profile.d/
```

Then configure OpenType fonts from TeX Live:

```bash
$ sudo cp $(kpsewhich -var-value TEXMFSYSVAR)/fonts/conf/texlive-fontconfig.conf \
/etc/fonts/conf.d/09-texlive.conf
$ sudo fc-cache -fsv
```

## Configuring `git`

This is my `git` configuration:

```bash
$ git config --global user.name "John Doe"
$ git config --global user.email johndoe@example.com
$ git config --global core.editor vim
$ git config --global push.default simple
```

*To be continued.* :wink:
