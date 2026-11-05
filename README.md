# Turtles

[![test](https://github.com/szermatt/turtles/workflows/test/badge.svg)](https://github.com/szermatt/turtles/actions)
[![Documentation Status](https://readthedocs.org/projects/turtles/badge/?version=latest)](https://turtles.readthedocs.io/en/latest/?badge=latest)
[![MELPA stable](https://stable.melpa.org/packages/turtles-badge.svg)](https://stable.melpa.org/#/turtles)
[![MELPA](https://melpa.org/packages/turtles-badge.svg)](https://melpa.org/#/turtles)

This package help write ERT-based tests to that check how Emacs
renders buffers and windows. The ERT tests can be run interactively or
in batch mode.

It's especially suited to test:

- the effect of display, before-string, after-string text properties
- the effect of overlays
- text visibility
- status line
- colors changes
- complex minibuffer interactions
- mouse, menu and button interactions

Read the full documentation on
[turtles.readthedocs.io](https://turtles.readthedocs.io/en/latest/index.html)
or in the info manual that comes with the package.

## Status

Version 2.1.0 is the latest version. Please depend on that tag.

Since this is a library, versioning matters: This project follows
[Semantic Versioning 2.0.0](https://semver.org/), that is, versions
follow the format MAJOR.MINOR.PATCH with:

- MAJOR incremented for incompatible API changes
- MINOR when functionality is added that is backward-compatible
- PATCH for bugfixes

To avoid surprises, you should aim to depend on a specific, tagged
version and only increase that version when you need to.

## How it works

Turtles starts another Emacs process inside of a term buffer, runs ERT
tests in that instance, and grabs snapshots of the display whenever
instructed.

The result is that the frame, minibuffer, window content, and status
line are available to tests as text with text properties specifying
attributes like colors and faces.

## Examples

A runnable version of the tests shown below can be found in [`test/turtles-examples-test.el`](https://github.com/szermatt/turtles/blob/master/test/turtles-examples-test.el). 

This is just a quick summary the complete guide, see the
[Tutorial](https://turtles.readthedocs.io/en/latest/tutorial.html).

### Screen Grabbing with Hello World

Create a buffer, render it, and check the displayed output:

```elisp
(turtles-ert-deftest turtles-examples-hello-world ()
  ;; The body of turtles-ert-deftest runs inside a
  ;; secondary Emacs instance.

  (ert-with-test-buffer ()
    (insert "hello, ") ; Fill in the buffer
    (insert (propertize "the " 'invisible t))
    (insert "world!\n")

    (turtles-with-grab-buffer () ; Grab current buffer content
      (should (equal "hello, world!"
                     (buffer-string))))))
```

- `turtles-ert-deftest` defines an ERT test that executes within a secondary Emacs instance (running inside a terminal buffer).
- `turtles-with-grab-buffer` ([reference](https://turtles.readthedocs.io/en/latest/reference.html#grab)) displays the buffer in a window, captures the terminal screen, and populates a temporary ERT test buffer with the result.

### Minibuffer with completing-read

Test interactive minibuffer completion using `turtles-with-minibuffer` ([reference](https://turtles.readthedocs.io/en/latest/reference.html#minibuffer)):

```elisp
(turtles-ert-deftest turtles-examples-test-completing-read ()
  (ert-with-test-buffer ()
    (let ((completing-read-function #'completing-read-default))
      (turtles-with-minibuffer
          (should
           (equal "Choice B"
                  (completing-read "Choose: " '("Choice A" "Choice B") nil t)))

        (turtles-with-grab-buffer (:name "initial prompt" :point "<>")
          (should (equal "Choose: <>" (buffer-string))))

        (execute-kbd-macro "Ch")
        (minibuffer-complete)
        (turtles-with-grab-buffer (:name "completion" :point "<>")
          (should (equal "Choose: Choice <>" (buffer-string))))

        (execute-kbd-macro "B")))))
```

- `(turtles-with-minibuffer READ BODY)` separates the call into:
  - `READ`: A sexp invoking a command that enters the minibuffer or a recursive edit (e.g. `completing-read`), returning its evaluation.
  - `BODY`: Forms executed interactively while `READ` is waiting for input.
- `:point "<>"` highlights the cursor position with `<>`.
- Interaction can be driven with `execute-kbd-macro` or direct calls to interactive commands (like `minibuffer-complete`). For commands requiring real event loop dispatch, `:keys` and `:command` keywords are available ([reference](https://turtles.readthedocs.io/en/latest/reference.html#interaction)).

### Top Bar Menu with the Mouse

Generate mouse events to open and interact with top bar menus:

```elisp
(turtles-ert-deftest turtles-example-menu ()
  (menu-bar-mode)

  (ert-with-test-buffer ()
    (turtles-example-mode)
    (pop-to-buffer (current-buffer))
    (turtles-interaction
      ;; Find and click on menu in the menu bar
      :mouse-ev 'mouse-1 (turtles-coords
                          "Turtle!" :menu-bar t)
      (turtles-with-grab-buffer (:menu t)
        (should
         (equal
          (concat
           " Turtle! >\n"
           " Swim\n"
           " Eat Lettuce\n"
           " Hide in Shell")
          (buffer-string))))

      ;; Click on item to select it
      :mouse-ev 'mouse-1 (turtles-coords
                          "Swim" :menu t))

    ;; Swim was executed
    (should (equal "weee!" (buffer-string)))))

(define-derived-mode turtles-example-mode fundamental-mode "Turtle!"
  "Sample major mode with a menu.")

(easy-menu-define turtles-example-mode-menu turtles-example-mode-map
  "Menu for `turtles-example-mode'."
  '("Turtle!"
    ["Swim" (lambda () (interactive) (insert "weee!"))]
    ["Eat Lettuce" (lambda () (interactive) (insert "*chomp* *chomp*"))]
    ["Hide in Shell" (lambda () (interactive) (insert "..."))]))
```

- `turtles-interaction` ([reference](https://turtles.readthedocs.io/en/latest/reference.html#interaction)) simulates user interactions in the event loop.
- `(turtles-coords "Turtle!" :menu-bar t)` ([reference](https://turtles.readthedocs.io/en/latest/reference.html#events)) locates text in the menu bar and returns its frame coordinates.
- `:mouse-ev 'mouse-1 POS` generates a mouse click to open the menu.
- `(turtles-with-grab-buffer (:menu t))` captures the popup menu content (requires Emacs 28+).

### Popup Menu with the Mouse

Interact with mode line popup menus using button press and release events:

```elisp
(turtles-ert-deftest turtles-example-mode-line-menu ()
  (ert-with-test-buffer ()
    ;; Keep the buffer name short, or the mode won't appear on the mode line.
    (rename-buffer "turtle" 'unique)

    (turtles-example-mode)
    (pop-to-buffer (current-buffer))
    (turtles-interaction
      ;; Find and press mouse button on menu in the mode line
      :mouse-ev 'down-mouse-1 (turtles-coords
                               "Turtle!" :mode-line (current-buffer))
      (turtles-with-grab-buffer (:menu t)
        (should
         (equal
          (concat
           " Turtle! Mode >\n"
           " Swim\n"
           " Eat Lettuce\n"
           " Hide in Shell")
          (buffer-string))))

      ;; Release button over item to select it.
      :mouse-ev 'up-mouse-1 (turtles-coords
                             "Eat Lettuce" :menu t))

    ;; Eat Lettuce was executed
    (should (equal "*chomp* *chomp*" (buffer-string)))))
```

- Generate button press (`'down-mouse-1`) and release (`'up-mouse-1`) events ([reference](https://turtles.readthedocs.io/en/latest/reference.html#interaction)).
- `(turtles-coords "Turtle!" :mode-line (current-buffer))` ([reference](https://turtles.readthedocs.io/en/latest/reference.html#events)) locates the mode string on the buffer's mode line.

## Installation

Install Turtles:

- on a recent version of Emacs (29 or later), from the
  github repository by doing `M-x package-vc-install https://github.com/szermatt/turtles`

- using [eldev](https://github.com/emacs-eldev/eldev) to run tests in
  batch mode:

  ```elisp

    (eldev-add-extra-dependencies 'test 'turtles)
    (eldev-use-vc-repository 'turtles :github "szermatt/turtles" :commit "2.0.1")
  ```

- from [MELPA](https://melpa.org/#/getting-started), by typing `M-x
  package-install turtles`. Note that there's no practical difference
  between the stable and unstable melpa package, as development
  happens on a branch. You'll always get the latest release.

Turtles requires Emacs 26.1 or later. Emacs 29.1 or later is recommended.

## Something is wrong!

Please check the [doc](https://turtles.readthedocs.io/en/latest/)
and, if that doesn't help, take the time to [file a bug report](https://turtles.readthedocs.io/en/latest/contrib.html#reporting-issues).

## Contributing

See the [Contributing](https://turtles.readthedocs.io/en/latest/contrib.html)
section of the documentation.



