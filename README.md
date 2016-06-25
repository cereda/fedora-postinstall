# Fedora 24 post installation guide

Welcome to my personal Fedora 24 post installation guide. In here, I try to describe most of steps I do after a clean install. Ideas and suggestions were collected from different sources, including [Fedy](http://folkswithhats.org/), and also from personal experience. Use this guide at your own risk and have fun with Fedora! :wink:

## Upgrade the entire system

First of all, let us update the entire system. I had a keyboard issue with my two Dell laptops after a clean F24 install and the upgrade fixed them right away, so this procedure is highly recommended (if not a mandatory step):

```bash
$ sudo dnf upgrade -y
```

## Enable RPM Fusion

Fedora already has great applications available out of the box. As to enhance the experience, let us add the repositories for contributed packages ([RPM Fusion](http://rpmfusion.org/)). First, download the repository entries:

```bash
$ wget http://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-24.noarch.rpm
$ wget http://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-24.noarch.rpm
```

Then, it is just a matter of installing these packages:

```bash
$ sudo dnf install rpmfusion-*
```

## Install the Flash plugin

Although Flash has been a cause of controversy, it is still needed in some websites. In order to install it, we need to add the Adobe repository to our system. First, download the repository entry:

```bash
$ wget http://linuxdownload.adobe.com/adobe-release/adobe-release-x86_64-1.0-1.noarch.rpm
```

And install it:

```bash
$ sudo dnf install adobe-release-*
```

Now, it is only a matter of asking `dnf` to install the package:

```bash
$ sudo dnf install flash-plugin
```

## Terminal with colours

This is almost sacred for me: having colours in my terminal. Create a file named `colours.sh` with the following content:

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

# Enable systemwide touchpad tap

In order to enable the touchpad tab systemwide, create a file named `00-enable-taps.conf` with the following content:

```bash
Section "InputClass"
    Identifier "tap-by-default"
    MatchIsTouchpad "on"
    Option "TapButton1" "1"
EndSection
```

And move it to `/etc/X11/xorg.conf.d/`:

```bash
$ sudo mv 00-enable-taps.conf /etc/X11/xorg.conf.d/
```

## Improve font rendering:

Fedora 24 has a great font support. I usually like to improve the font rendering with the following tweak. First of all, we need to install `freetype-freeworld`:

```bash
$ sudo dnf install freetype-freeworld
```

Then create a file named `local.conf` with the following content:

```xml
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
    <match target="pattern">
        <edit name="dpi" mode="assign">96</edit>
    </match>
    <match target="font">
        <edit mode="assign" name="antialias" >
            <bool>true</bool>
        </edit>
    </match>
    <match target="font">
        <edit mode="assign" name="hinting" >
            <bool>true</bool>
        </edit>
    </match>
    <match target="font">
        <edit mode="assign" name="hintstyle" >
            <const>hintslight</const>
        </edit>
    </match>
    <match target="font">
        <edit mode="assign" name="rgba" >
            <const>rgb</const>
        </edit>
    </match>
    <match target="font">
        <edit mode="assign" name="lcdfilter">
            <const>lcddefault</const>
        </edit>
    </match>
</fontconfig>
```

And move it to `/etc/fonts/`:

```bash
$ sudo mv local.conf /etc/fonts/
```

## A nice icon theme

Beauty is in the eye of the behold, but I really like the Breeze icon theme, already in the official repositories:

```bash
$ sudo dnf install breeze-icon-theme
```

In order to ease the setup, let us install the GNOME Tweak Tool as well:

```bash
$ sudo dnf install gnome-tweak-tool
```

## Recommended multimedia packages

Let us now install some recommended multimedia packages:

```bash
$ sudo dnf install faad2 flac gstreamer1-libav gstreamer1-plugins-bad-freeworld \
gstreamer1-plugins-ugly gstreamer-ffmpeg gstreamer-plugins-espeak gstreamer-plugins-fc \
gstreamer-plugins-ugly gstreamer-rtsp lame libdca libmad libmatroska x264 xvidcore \
gstreamer1-plugins-bad-free gstreamer1-plugins-base gstreamer1-plugins-good \
gstreamer-plugins-bad gstreamer-plugins-bad-free gstreamer-plugins-base \
gstreamer-plugins-good
```

I also like to include these players and tools:

```bash
$ sudo dnf install mencoder mplayer mpv vlc ffmpeg
```

## Other useful applications

I also install the following applications:

```bash
$ sudo dnf install cabextract lzip nano p7zip p7zip-plugins
```

Pick only the ones you need, of course:

```bash
$ sudo dnf install thunderbird potrace inkscape poedit emacs qbittorrent \
lilypond frescobaldi texworks ack vim-enhanced vim-X11 maven scala clojure \
java-1.8.0-openjdk java-1.8.0-openjdk-headless java-1.8.0-openjdk-devel \
python-sphinx asciidoc asciidoc-latex asciinema rubygem-rake subversion \
git-cola mercurial sl gti htop f24-backgrounds f24-backgrounds-base \
f24-backgrounds-extras-base f24-backgrounds-extras-gnome bleachbit \
axel ipython zsh
```

## Install Powerline

Powerline is also included in Fedora 24:

```bash
$ sudo dnf install powerline
```

## Vim setup

I like to recommend the [Janus](https://github.com/carlhuda/janus) distribution for `vim` users. To install it, just run:

```bash
$ curl -L https://bit.ly/janus-bootstrap | bash
```

Then, I create a `.janus` directory in my `$HOME`:

```bash
$ mkdir ~/.janus
```

And populate it with the `vim` plugins I use:

```
$ cd ~/.janus
$ git clone git://github.com/tpope/vim-characterize.git
$ git clone git://github.com/tpope/vim-fugitive.git
$ git clone git://github.com/tpope/vim-scriptease.git
$ git clone git://github.com/tpope/vim-surround.git
$ git clone git://github.com/tpope/vim-unimpaired.git
$ git clone https://github.com/godlygeek/tabular.git
$ git clone https://github.com/chrisbra/unicode.vim.git
$ git clone https://github.com/SirVer/ultisnips.git
$ git clone https://github.com/Shougo/vimproc.vim.git
$ git clone https://github.com/Shougo/vimshell.vim.git
$ git clone https://github.com/vim-airline/vim-airline.git
```

My `.vimrc.before` setup:

```vim
let g:tex_flavor = 'latex'
let g:airline_powerline_fonts = 1
let g:airline#extensions#tabline#enabled = 1
call janus#disable_plugin('vim-snipmate')
```

My `.vimrc.after` setup:

```vim
color desert
```

My `.gvimrc.after` setup:

```vim
color molokai
set guifont=Droid\ Sans\ Mono\ for\ Powerline\ 11
```

## Fortune cookies in the terminal:

This is mandatory! First of all, we need to install `fortune-mod`:

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

## Install Powerline fonts

Powerline fonts are patched in order to include different glyphs. Here is how to install them:

```bash
$ wget https://github.com/powerline/fonts/archive/master.zip
$ unzip master.zip
$ cd fonts-master/
$ ./install.sh
$ sudo fc-cache -fsv ~/.local/share/fonts
```

## Emacs setup

I like to recommend the [Spacemacs](https://github.com/syl20bnr/spacemacs) distribution for `emacs`, just run:

```bash
$ git clone https://github.com/syl20bnr/spacemacs ~/.emacs.d
```

## A fancy Z shell

A great enhancement to `zsh` is [Oh my `zsh`](https://github.com/robbyrussell/oh-my-zsh). I personally don't like the last part of the install script, as it changes your current shell. I usually prefer downloading the script:

```bash
$ wget https://raw.githubusercontent.com/robbyrussell/oh-my-zsh/master/tools/install.sh
```

Then edit `install.sh`, comment the parts I don't want and then run with:

```bash
$ sh install
```

## Install and configure TeX Live

This is also mandatory! Let us get the install script from TUG and run:

```bash
$ sudo dnf install perl-Digest-MD5
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

## Configuring Git

This is my `git` configuration:

```bash
$ git config --global user.name "John Doe"
$ git config --global user.email johndoe@example.com
$ git config --global core.editor vim
$ git config --global push.default simple
```

*To be continued.* :wink:
