# Fedora post installation guide

Welcome to my personal Fedora post installation guide. In here, I try to describe most of steps I do after a clean install. Ideas and suggestions were collected from different sources, including [Fedy](http://folkswithhats.org/), and also from personal experience. Use this guide at your own risk and have fun with Fedora! :wink:

## Upgrade the entire system

First of all, let us update the entire system after a clean Fedora install. This procedure is highly recommended (if not a mandatory step), as a lot of potential bugs that could not be fixed for the distro release might already have a patch by now. Open the terminal and type:

```bash
$ sudo dnf upgrade -y
```

## Enable RPM Fusion

Fedora already has great applications available out of the box. As to enhance the experience, let us add the repositories for contributed packages ([RPM Fusion](http://rpmfusion.org/)). We can configure it in one line:

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

There is no need to restart your entire session. Simply restart your terminal and have fun!

## Improve font rendering

Fedora has a great font support. I used to rely on an specific release of Freetype available in the contributed repositories, but this procedure became obsolete. It is quite certain that you already have the default `freetype` package installed in your machine, so let us tweak our font configuration. In order to ease our setup, I highly suggest installing the Gnome Tweaks tool:

```bash
$ sudo dnf install gnome-tweaks
```

Now, open this tool we have just installed and set _subpixel antialising_ in the _Fonts_ section. You can tweak a lot of things, so your mileage can greatly vary.

## Useful packages

These are some packages I like to install. Use them at your own risk!

1. Lilypond and Frescobaldi for writing sheet music. The former is the actual engraver, the latter is a nice editor for such files. 

    ```bash
    $ sudo dnf install lilypond frescobaldi
    ```

2. Timidity for playing MIDI files. I also included the corresponding multimedia codec for use in other applications.

    ```bash
    $ sudo dnf install timidity++ \
    gstreamer1-plugins-bad-free-fluidsynth
    ```

3. MPV as a multimedia player, and FFmpeg and Lame for conversion.

    ```bash
    $ sudo dnf install mpv ffmpeg lame
    ```

4. Some useful command line archiving tools.

    ```bash
    $ sudo dnf install p7zip p7zip-plugins unrar
    ```

5. Editors in general. Note that `vim`, `emacs` and `nano` are the typical command line editors. I included Leafpad as it is a very lightweight editor, and TeXworks as it is one of the nicest TeX editors out there.

    ```bash
    $ sudo dnf install vim emacs leafpad nano texworks
    ```

6. Graphic design editors and utilities.

    ```bash
    $ sudo dnf install inkscape gimp potrace ImageMagick
    ```

7. Backgrounds.

    ```bash
    $ sudo dnf install f$(rpm -E %fedora)-backgrounds \
    f$(rpm -E %fedora)-backgrounds-base \
    f$(rpm -E %fedora)-backgrounds-gnome \
    f$(rpm -E %fedora)-backgrounds-animated \
    f$(rpm -E %fedora)-backgrounds-extras-base \
    f$(rpm -E %fedora)-backgrounds-extras-gnome
    ```

8. The latest Java virtual machine.

    ```bash
    $ sudo dnf install java-latest-openjdk \
    java-latest-openjdk-jmods \
    java-latest-openjdk-devel \
    java-latest-openjdk-headless
    ```

Pick only the ones you need, of course:

```bash
$ sudo dnf install thunderbird poedit qbittorrent \
ack  maven scala clojure \
java-1.8.0-openjdk java-1.8.0-openjdk-headless java-1.8.0-openjdk-devel \
python-sphinx asciidoc asciidoc-latex asciinema rubygem-rake subversion \
git-cola mercurial sl gti htop \
 bleachbit \
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
