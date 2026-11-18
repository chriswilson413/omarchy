import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/clipboard/ClipboardHistory.js" as ClipboardHistory

// Drives the real clipboard plugin, never shown, over a seeded history: the
// startup sweep, a queued image the history on disk still lists, a removal, a
// recopy that replaces an entry, and clear all.
ShellRoot {
  id: root

  property string resultPath: Quickshell.env("OMARCHY_QML_TEST_RESULT")
  property string imageA: Quickshell.env("CLIPBOARD_IMAGE_A")
  property string imageB: Quickshell.env("CLIPBOARD_IMAGE_B")
  property string recopyB: Quickshell.env("CLIPBOARD_RECOPY_B")
  property string orphan: Quickshell.env("CLIPBOARD_ORPHAN")
  property string historyPath: Quickshell.env("HOME") + "/.local/state/omarchy/clipboard-history.json"
  property var failures: []
  property var clipboard: loader.item
  property var pendingShell: null
  property var pendingTimer: null

  function check(condition, message) {
    if (!condition) failures.push(message)
  }

  function finish() {
    var payload = JSON.stringify({ ok: failures.length === 0, failures: failures })
    Quickshell.execDetached(["bash", "-c", "printf '%s' \"$1\" >\"$2\"", "bash", payload, resultPath])
  }

  function after(interval, callback) {
    pendingTimer = callback
    timer.interval = interval
    timer.start()
  }

  // One line per path, yes or no, then the saved history compacted, or "unreadable".
  function inspect(paths, callback) {
    var script = "for p; do [[ -e $p ]] && echo yes || echo no; done; jq -c . \"" + historyPath + "\" 2>/dev/null || echo unreadable"
    pendingShell = function(text) { callback(text.split("\n")) }
    shell.command = ["bash", "-c", script, "bash"].concat(paths)
    shell.running = true
  }

  // Polls until the files are present or gone as expected, or the deadline passes.
  function waitForFiles(paths, expected, callback) {
    var deadline = Date.now() + 2000
    var poll = function() {
      inspect(paths, function(lines) {
        if (lines.slice(0, expected.length).join() === expected.join() || Date.now() > deadline) return callback(lines)
        after(100, poll)
      })
    }
    poll()
  }

  function waitUntil(condition, callback) {
    var deadline = Date.now() + 2000
    var poll = function() {
      if (condition() || Date.now() > deadline) return callback()
      after(100, poll)
    }
    poll()
  }

  function removeImage(path) {
    var same = function(text) { return String(text) }
    var rows = ClipboardHistory.displayRows(clipboard.history, "", 50, same, same, same)
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].path === path) {
        clipboard.rebuildDisplay()
        clipboard.removeDisplayIndex(i)
        return true
      }
    }
    return false
  }

  Process {
    id: shell
    stdout: StdioCollector {
      onStreamFinished: {
        var callback = root.pendingShell
        root.pendingShell = null
        if (callback) callback(text.trim())
      }
    }
  }

  Timer {
    id: timer
    onTriggered: {
      var callback = root.pendingTimer
      root.pendingTimer = null
      callback()
    }
  }

  Loader {
    id: loader
    source: Qt.resolvedUrl("plugins/clipboard/Clipboard.qml")
  }

  Component.onCompleted: waitUntil(function() { return !!clipboard && clipboard.history.length === 3 }, startupSwept)

  function startupSwept() {
    if (!clipboard || clipboard.history.length !== 3) {
      check(false, "the clipboard plugin loads the seeded history")
      return finish()
    }
    waitForFiles([imageA, imageB, orphan], ["yes", "yes", "no"], function(lines) {
      check(lines[0] === "yes" && lines[1] === "yes", "the startup sweep keeps listed images, however old")
      check(lines[2] === "no", "the startup sweep removes an aged image the history doesn't list")
      // As after a saved() whose write never reached the disk: the history there still lists A.
      clipboard.deleteImageFiles([imageA])
      clipboard.flushImageDeletes()
      waitUntil(function() { return clipboard.pendingImageDeletes.indexOf(imageA) !== -1 }, stillListed)
    })
  }

  function stillListed() {
    check(clipboard.pendingImageDeletes.indexOf(imageA) !== -1, "an image the history on disk still lists goes back into the queue")
    inspect([imageA], function(lines) {
      check(lines[0] === "yes", "an image the history on disk still lists is kept")
      // Removal must queue A by itself.
      clipboard.pendingImageDeletes = []
      check(removeImage(imageA), "the listed image is a panel row")
      waitForFiles([imageA, imageB], ["no", "yes"], removed)
    })
  }

  function removed(lines) {
    check(lines[0] === "no", "removing an entry deletes its image once the history is saved")
    check(lines[1] === "yes", "removing an entry keeps other images")
    check(lines[2].indexOf(imageA) === -1, "the saved history no longer lists the removed image")
    clipboard.addClipboardJson(JSON.stringify({ type: "image", path: recopyB, mime: "image/png" }))
    waitForFiles([imageB, recopyB], ["no", "yes"], recopied)
  }

  function recopied(lines) {
    check(lines[0] === "no", "a recopy deletes the image of the entry it replaces")
    check(lines[1] === "yes", "a recopy keeps its own image")
    pendingShell = function() {
      clipboard.confirmClearHistory()
      waitForFiles([recopyB, orphan], ["no", "no"], cleared)
    }
    shell.command = ["touch", "-d", "2 minutes ago", orphan]
    shell.running = true
  }

  function cleared(lines) {
    check(lines[0] === "no", "clear all deletes a listed image once the empty history is saved")
    check(lines[1] === "no", "clear all sweeps an orphan as well")
    check(lines[2] === "[]", "clear all saves an empty history")
    finish()
  }
}
