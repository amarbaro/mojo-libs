# Sourced by the other scripts, from the repository root: sets MOJO and HASHLIB_SRC.
# mojo-hashlib comes from a sibling checkout, else a pinned clone under .work/deps.
if [ -z "${MOJO:-}" ]; then
  if [ -x .venv/bin/mojo ]; then MOJO=.venv/bin/mojo; else MOJO=mojo; fi
fi
if [ -z "${HASHLIB_SRC:-}" ]; then
  if [ -d ../mojo-hashlib-public/src ]; then HASHLIB_SRC=../mojo-hashlib-public/src
  elif [ -d ../mojo-hashlib/src ]; then HASHLIB_SRC=../mojo-hashlib/src
  else
    if [ ! -d .work/deps/mojo-hashlib ]; then
      mkdir -p .work/deps
      git clone -q --depth 1 --branch v0.1.2 https://github.com/amarbaro/mojo-hashlib .work/deps/mojo-hashlib || { echo "FAIL setup: clone mojo-hashlib"; exit 1; }
    fi
    HASHLIB_SRC=.work/deps/mojo-hashlib/src
  fi
fi
export MOJO HASHLIB_SRC
