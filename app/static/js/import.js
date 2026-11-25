(function () {
  "use strict";

  var app = document.getElementById("import-app");
  if (!app) {
    return;
  }

  var csrf = app.getAttribute("data-csrf") || "";
  var drivePicker = document.getElementById("drive-picker");
  var driveChip = document.getElementById("drive-chip");
  var tree = document.getElementById("import-tree");
  var stateEl = document.getElementById("import-state");
  var stateTitle = document.getElementById("import-state-title");
  var stateNote = document.getElementById("import-state-note");
  var destination = document.getElementById("destination");
  var selectionSummary = document.getElementById("selection-summary");
  var skipSummary = document.getElementById("skip-summary");
  var freeHead = document.getElementById("free-head");
  var freeMeter = document.getElementById("free-meter");
  var freeFill = document.getElementById("free-meter-fill");
  var freeNote = document.getElementById("free-note");
  var startButton = document.getElementById("start-import");
  var statusEl = document.getElementById("import-status");
  var resultEl = document.getElementById("import-result");
  var runTitle = document.getElementById("run-title");
  var runChip = document.getElementById("run-chip");
  var runNote = document.getElementById("run-note");
  var runMeter = document.getElementById("run-meter");
  var runFill = document.getElementById("run-meter-fill");
  var runLink = document.getElementById("run-link");

  var TREE_PAGE_SIZE = 200;
  var PREVIEW_DELAY_MS = 180;
  var STATUS_LABELS = {
    queued: ["Queued", "chip-info"],
    running: ["Running", "chip-live"],
    completed: ["Completed", "chip-ok"],
    completed_with_errors: ["Completed with errors", "chip-warn"],
    interrupted: ["Interrupted", "chip-idle"],
    failed: ["Failed", "chip-bad"]
  };
  var TERMINAL = {
    completed: true,
    completed_with_errors: true,
    interrupted: true,
    failed: true,
    missing: true
  };

  var selection = new Map();
  var rowByPath = new Map();
  var inventoryId = "";
  var preview = null;
  var previewTimer = null;
  var previewSeq = 0;
  var submitting = false;
  var stream = null;

  function icon(symbol, size) {
    var ns = "http://www.w3.org/2000/svg";
    var svg = document.createElementNS(ns, "svg");
    svg.setAttribute("width", String(size));
    svg.setAttribute("height", String(size));
    svg.setAttribute("aria-hidden", "true");
    var use = document.createElementNS(ns, "use");
    use.setAttribute("href", symbol);
    svg.appendChild(use);
    return svg;
  }

  function formatBytes(value) {
    var size = Math.max(Number(value) || 0, 0);
    if (!size) {
      return "0 B";
    }
    var units = ["B", "KB", "MB", "GB", "TB", "PB"];
    var amount = size;
    var index = 0;
    while (amount >= 1000 && index < units.length - 1) {
      amount /= 1000;
      index += 1;
    }
    if (index === 0) {
      return Math.round(amount) + " B";
    }
    var precision = units[index] === "TB" || units[index] === "PB" ? 2 : 1;
    var text = amount
      .toFixed(precision)
      .replace(/\.0+$/, "")
      .replace(/(\.\d*?)0+$/, "$1");
    return text + " " + units[index];
  }

  function baseName(relPath) {
    var parts = relPath.split("/");
    return parts[parts.length - 1];
  }

  function setStatus(message, isError) {
    if (!statusEl) {
      return;
    }
    statusEl.textContent = message || "";
    statusEl.classList.toggle("is-error", Boolean(isError));
  }

  function setState(kind, title, note) {
    if (!stateEl) {
      return;
    }
    stateEl.dataset.kind = kind;
    stateTitle.textContent = title;
    stateNote.textContent = note;
    stateEl.hidden = false;
    if (tree) {
      tree.hidden = true;
    }
  }

  function showTree() {
    if (stateEl) {
      stateEl.hidden = true;
    }
    if (tree) {
      tree.hidden = false;
    }
  }

  function clearTree() {
    if (tree) {
      tree.textContent = "";
      tree.hidden = true;
    }
    rowByPath.clear();
  }

  function selectedDriveOption() {
    if (!drivePicker) {
      return null;
    }
    return drivePicker.options[drivePicker.selectedIndex] || null;
  }

  function driveState(option) {
    var status = option ? option.getAttribute("data-status") : "none";
    var error = option ? option.getAttribute("data-error") : "";
    if (status === "complete") {
      return {
        kind: "ready",
        title: "Loading the drive tree.",
        note: "Folders open on demand; nothing is selected yet."
      };
    }
    if (status === "scanning") {
      return {
        kind: "scanning",
        title: "Inventory is still scanning.",
        note: "The file tree appears here when the scan finishes."
      };
    }
    if (status === "failed") {
      return {
        kind: "failed",
        title: "Inventory failed.",
        note:
          error ||
          "The drive could not be read. Reconnect it to inventory it again."
      };
    }
    if (status === "none") {
      return {
        kind: "none",
        title: "No inventory yet.",
        note: "The file tree appears after the drive is inventoried."
      };
    }
    return {
      kind: "pending",
      title: "Inventory " + status + ".",
      note: "The file tree appears when the inventory is complete."
    };
  }

  function updateChip(option) {
    if (!driveChip || !option) {
      return;
    }
    var chip = option.getAttribute("data-chip") || "chip-neutral";
    driveChip.className = "chip " + chip;
    driveChip.textContent = option.getAttribute("data-chip-label") || "Not ready";
  }

  function updateFreeSpace() {
    if (!destination) {
      return;
    }
    var option = destination.options[destination.selectedIndex];
    if (!option) {
      return;
    }
    var name = option.getAttribute("data-name") || option.textContent;
    var free = Number(option.getAttribute("data-free-bytes")) || 0;
    var total = Number(option.getAttribute("data-total-bytes")) || 0;
    var available = option.getAttribute("data-available") === "true";
    var used = total > 0 ? Math.round(((total - free) / total) * 100) : 0;
    used = Math.max(0, Math.min(100, used));

    if (freeFill) {
      freeFill.style.width = used + "%";
    }
    if (freeMeter) {
      freeMeter.setAttribute(
        "aria-label",
        name + " destination is " + used + " percent full"
      );
    }
    if (freeHead) {
      freeHead.textContent = total > 0 ? used + "% used" : "—";
    }
    if (freeNote) {
      var note = available
        ? option.getAttribute("data-free") + " on " + name
        : "Destination space is unavailable.";
      if (preview && preview.bytes) {
        note += " · " + formatBytes(preview.bytes) + " selected";
      }
      freeNote.textContent = note;
    }
  }

  function updateSummary() {
    var roots = selection.size;
    if (!roots) {
      selectionSummary.textContent = "No files selected.";
      skipSummary.hidden = true;
      return;
    }
    if (preview) {
      var text =
        roots +
        (roots === 1 ? " item, " : " items, ") +
        preview.files +
        (preview.files === 1 ? " file, " : " files, ") +
        formatBytes(preview.bytes);
      selectionSummary.textContent = text;
      var exists = preview.skip_counts.exists || 0;
      var conflict = preview.skip_counts.conflict || 0;
      if (exists || conflict) {
        var parts = [];
        if (exists) {
          parts.push(exists + " already copied");
        }
        if (conflict) {
          parts.push(conflict + (conflict === 1 ? " conflict" : " conflicts"));
        }
        skipSummary.textContent = "Will skip: " + parts.join(", ") + ".";
        skipSummary.hidden = false;
      } else {
        skipSummary.hidden = true;
      }
      return;
    }
    selectionSummary.textContent =
      roots + (roots === 1 ? " item selected" : " items selected");
    skipSummary.hidden = true;
  }

  function updateConfirm() {
    if (!startButton) {
      return;
    }
    var ready =
      Boolean(inventoryId) &&
      selection.size > 0 &&
      preview !== null &&
      preview.files > 0 &&
      !submitting;
    startButton.disabled = !ready;
  }

  function clearPreviewBadges() {
    rowByPath.forEach(function (row) {
      var badges = row.querySelectorAll("[data-preview-skip]");
      for (var index = 0; index < badges.length; index += 1) {
        badges[index].remove();
      }
    });
  }

  function applySkipBadges(skipped) {
    if (!skipped || !skipped.length) {
      return;
    }
    var byRoot = new Map();
    skipped.forEach(function (item) {
      var root = null;
      selection.forEach(function (value, key) {
        if (item.path === key || item.path.indexOf(key + "/") === 0) {
          if (root === null || key.length > root.length) {
            root = key;
          }
        }
      });
      if (root === null) {
        return;
      }
      var counts = byRoot.get(root) || { exists: 0, conflict: 0 };
      counts[item.reason] += 1;
      byRoot.set(root, counts);
    });
    byRoot.forEach(function (counts, root) {
      var row = rowByPath.get(root);
      if (!row) {
        return;
      }
      var tag = document.createElement("span");
      tag.setAttribute("data-preview-skip", "true");
      if (counts.conflict) {
        tag.className = "tag tag-bad";
        tag.textContent =
          counts.conflict +
          (counts.conflict === 1 ? " conflict" : " conflicts");
      } else {
        tag.className = "tag tag-neutral";
        tag.textContent = counts.exists + " skipped";
      }
      row.insertBefore(tag, row.querySelector(".tree-size"));
    });
  }

  function invalidatePreview() {
    preview = null;
    previewSeq += 1;
    clearPreviewBadges();
    updateConfirm();
  }

  function schedulePreview() {
    previewSeq += 1;
    window.clearTimeout(previewTimer);
    previewTimer = window.setTimeout(runPreview, PREVIEW_DELAY_MS);
  }

  function parseBody(response) {
    return response.text().then(function (text) {
      if (!text) {
        return {};
      }
      try {
        return JSON.parse(text);
      } catch (error) {
        return {};
      }
    });
  }

  function runPreview() {
    var paths = Array.from(selection.keys());
    preview = null;
    if (!paths.length || !inventoryId) {
      setStatus("", false);
      clearPreviewBadges();
      updateSummary();
      updateFreeSpace();
      updateConfirm();
      return;
    }
    var seq = previewSeq + 1;
    previewSeq = seq;
    updateSummary();
    updateConfirm();
    fetch("/api/imports/preview", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        inventory_id: Number(inventoryId),
        destination: destination.value,
        paths: paths
      })
    })
      .then(function (response) {
        return parseBody(response).then(function (body) {
          return { response: response, body: body };
        });
      })
      .then(function (result) {
        if (seq !== previewSeq) {
          return;
        }
        if (!result.response.ok) {
          if (result.response.status === 401) {
            setStatus("Session expired. Sign in again.", true);
          } else {
            setStatus(
              result.body.detail || "Could not check the selection.",
              true
            );
          }
          preview = null;
          clearPreviewBadges();
          updateSummary();
          updateFreeSpace();
          updateConfirm();
          return;
        }
        setStatus("", false);
        preview = result.body;
        clearPreviewBadges();
        applySkipBadges(preview.skipped);
        updateSummary();
        updateFreeSpace();
        updateConfirm();
        if (preview.files === 0) {
          setStatus(
            "Everything selected is already at the destination or conflicts.",
            false
          );
        }
      })
      .catch(function () {
        if (seq !== previewSeq) {
          return;
        }
        preview = null;
        setStatus("Could not check the selection. Try again.", true);
        clearPreviewBadges();
        updateSummary();
        updateFreeSpace();
        updateConfirm();
      });
  }

  function toggleSelection(entry) {
    if (selection.has(entry.rel_path)) {
      selection.delete(entry.rel_path);
    } else {
      selection.set(entry.rel_path, true);
    }
    invalidatePreview();
    resetStartedRun();
    schedulePreview();
    updateSummary();
    updateConfirm();
  }

  function resetStartedRun() {
    if (submitting) {
      return;
    }
    if (stream) {
      stream.close();
      stream = null;
    }
    if (resultEl) {
      resultEl.hidden = true;
    }
    setStatus("", false);
  }

  function duplicateTag(state) {
    if (state !== "exists" && state !== "conflict") {
      return null;
    }
    var tag = document.createElement("span");
    if (state === "conflict") {
      tag.className = "tag tag-bad";
      tag.textContent = "Conflict";
    } else {
      tag.className = "tag tag-neutral";
      tag.textContent = "Already copied";
    }
    return tag;
  }

  function mediaTag(kind) {
    if (kind !== "movie" && kind !== "series") {
      return null;
    }
    var tag = document.createElement("span");
    tag.className = "tag tag-neutral";
    tag.textContent = kind === "movie" ? "Movie" : "Series";
    return tag;
  }

  function buildRow(entry) {
    var row = document.createElement("div");
    row.className = "tree-row";
    row.setAttribute("data-path", entry.rel_path);
    rowByPath.set(entry.rel_path, row);

    var checkbox = document.createElement("input");
    checkbox.type = "checkbox";
    checkbox.className = "tree-check";
    checkbox.setAttribute("aria-label", "Select " + entry.rel_path);
    checkbox.checked = selection.has(entry.rel_path);
    checkbox.addEventListener("change", function () {
      toggleSelection(entry);
    });

    row.appendChild(checkbox);

    var symbol = "#i-copy";
    if (entry.is_dir) {
      symbol = "#i-folder";
    } else if (entry.kind === "movie") {
      symbol = "#i-film";
    } else if (entry.kind === "series") {
      symbol = "#i-series";
    }
    row.appendChild(icon(symbol, 16)).classList.add("tree-icon");

    var name = document.createElement("span");
    name.className = "tree-name";
    name.textContent = baseName(entry.rel_path);
    row.appendChild(name);

    var duplicate = duplicateTag(entry.duplicate_state);
    if (duplicate) {
      row.appendChild(duplicate);
    }
    var media = mediaTag(entry.kind);
    if (media) {
      row.appendChild(media);
    }

    if (!entry.is_dir) {
      var size = document.createElement("span");
      size.className = "tree-size mono";
      size.textContent = formatBytes(entry.size);
      row.appendChild(size);
    }
    return row;
  }

  function buildItem(entry) {
    var item = document.createElement("li");
    var row = buildRow(entry);
    item.appendChild(row);
    if (entry.is_dir) {
      var children = document.createElement("ul");
      children.className = "tree-children";
      children.hidden = true;
      item.appendChild(children);
      attachTwisty(row, entry, item);
    } else {
      var space = document.createElement("span");
      space.className = "twisty-space";
      space.setAttribute("aria-hidden", "true");
      row.insertBefore(space, row.firstChild);
    }
    return item;
  }

  function clearList(list) {
    var rows = list.querySelectorAll(".tree-row[data-path]");
    for (var index = 0; index < rows.length; index += 1) {
      rowByPath.delete(rows[index].getAttribute("data-path"));
    }
    list.textContent = "";
  }

  function appendEntries(list, parent, offset, body) {
    if (offset === 0) {
      clearList(list);
    }
    var more = list.querySelector(".tree-more");
    if (more) {
      more.remove();
    }
    body.entries.forEach(function (entry) {
      list.appendChild(buildItem(entry));
    });
    if (!body.entries.length && offset === 0) {
      var empty = document.createElement("li");
      empty.className = "tree-empty";
      empty.appendChild(icon("#i-folder", 14));
      empty.appendChild(document.createTextNode("No files in this folder."));
      list.appendChild(empty);
    }
    if (body.total > offset + body.entries.length) {
      var nextOffset = offset + body.entries.length;
      var moreItem = document.createElement("li");
      moreItem.className = "tree-more";
      var moreButton = document.createElement("button");
      moreButton.type = "button";
      moreButton.className = "btn btn-quiet";
      moreButton.textContent = "Show more";
      moreButton.addEventListener("click", function () {
        loadChildren(list, parent, nextOffset, true).catch(function (error) {
          setStatus(error.message, true);
        });
      });
      moreItem.appendChild(moreButton);
      list.appendChild(moreItem);
    }
  }

  function loadChildren(list, parent, offset, append) {
    var url =
      "/api/inventories/" +
      encodeURIComponent(inventoryId) +
      "?parent=" +
      encodeURIComponent(parent) +
      "&limit=" +
      TREE_PAGE_SIZE +
      "&offset=" +
      offset;
    return fetch(url)
      .then(function (response) {
        return parseBody(response).then(function (body) {
          return { response: response, body: body };
        });
      })
      .then(function (result) {
        if (!result.response.ok) {
          var message =
            result.response.status === 401
              ? "Session expired. Sign in again."
              : result.body.detail || "Could not load the drive tree.";
          throw new Error(message);
        }
        appendEntries(list, parent, append ? offset : 0, result.body);
        return result.body;
      });
  }

  function toggleFolder(item, button) {
    var children = item.querySelector(".tree-children");
    if (!children) {
      return;
    }
    if (button.getAttribute("aria-expanded") === "true") {
      button.setAttribute("aria-expanded", "false");
      children.hidden = true;
      return;
    }
    button.setAttribute("aria-expanded", "true");
    children.hidden = false;
    if (children.getAttribute("data-loaded") === "true") {
      return;
    }
    children.setAttribute("data-loaded", "true");
    var row = item.querySelector(".tree-row");
    var parent = row ? row.getAttribute("data-path") : "";
    loadChildren(children, parent, 0, false).catch(function (error) {
      children.setAttribute("data-loaded", "false");
      setStatus(error.message, true);
    });
  }

  function attachTwisty(row, entry, item) {
    var button = document.createElement("button");
    button.type = "button";
    button.className = "twisty";
    button.setAttribute("aria-expanded", "false");
    button.setAttribute("aria-label", "Expand " + baseName(entry.rel_path));
    button.appendChild(icon("#i-chevron", 14));
    button.addEventListener("click", function () {
      toggleFolder(item, button);
    });
    row.insertBefore(button, row.firstChild);
  }

  function loadTree() {
    if (!inventoryId || !tree) {
      return;
    }
    setState("ready", "Loading the drive tree.", "Folders open on demand.");
    loadChildren(tree, "", 0, false)
      .then(function (body) {
        if (!body.total) {
          clearTree();
          setState(
            "empty",
            "This drive is empty.",
            "No files were found in the inventory."
          );
          return;
        }
        showTree();
      })
      .catch(function (error) {
        clearTree();
        setState("error", "Could not load the drive tree.", error.message);
      });
  }

  function selectDrive() {
    var option = selectedDriveOption();
    selection = new Map();
    preview = null;
    previewSeq += 1;
    window.clearTimeout(previewTimer);
    resetStartedRun();
    updateChip(option);
    clearTree();
    if (!option) {
      inventoryId = "";
      setState("no-drive", "No drive connected.", "Plug in a USB drive to begin.");
      updateSummary();
      updateConfirm();
      return;
    }
    inventoryId = option.getAttribute("data-inventory") || "";
    app.setAttribute("data-inventory", inventoryId);
    var state = driveState(option);
    setState(state.kind, state.title, state.note);
    updateSummary();
    updateFreeSpace();
    updateConfirm();
    if (state.kind === "ready") {
      loadTree();
    }
  }

  function setRunChip(status) {
    var label = STATUS_LABELS[status] || [status, "chip-neutral"];
    runChip.className = "chip " + label[1];
    runChip.textContent = label[0];
  }

  function followRun(runId) {
    if (stream) {
      stream.close();
      stream = null;
    }
    if (!window.EventSource) {
      runNote.textContent =
        "Run " + runId + " is queued. Live progress needs EventSource.";
      return;
    }
    var source = new window.EventSource(
      "/api/events/stream?run_id=" + encodeURIComponent(runId)
    );
    stream = source;
    var errors = 0;
    source.onmessage = function (event) {
      errors = 0;
      var snapshot;
      try {
        snapshot = JSON.parse(event.data);
      } catch (error) {
        return;
      }
      if (snapshot.status === "missing") {
        runNote.textContent = "This run is not available.";
        source.close();
        stream = null;
        return;
      }
      setRunChip(snapshot.status);
      var total = Number(snapshot.bytes_total) || 0;
      var done = Number(snapshot.bytes_done) || 0;
      var percent = total > 0 ? Math.round((done * 100) / total) : 0;
      percent = Math.max(0, Math.min(100, percent));
      runFill.style.width = percent + "%";
      runMeter.setAttribute("aria-valuenow", String(percent));
      var counts = snapshot.item_counts || {};
      var finished =
        (Number(counts.completed) || 0) + (Number(counts.failed) || 0);
      var files = Number(snapshot.files_total) || 0;
      runNote.textContent =
        formatBytes(done) +
        " of " +
        formatBytes(total) +
        " · " +
        finished +
        " of " +
        files +
        " files finished";
      if (TERMINAL[snapshot.status]) {
        source.close();
        stream = null;
        setStatus("Run " + runId + " " + STATUS_LABELS[snapshot.status][0].toLowerCase() + ".", false);
      }
    };
    source.onerror = function () {
      errors += 1;
      if (source.readyState === window.EventSource.CLOSED || errors > 2) {
        source.close();
        stream = null;
        setStatus(
          "Live progress stopped. Open the run for the latest state.",
          true
        );
      }
    };
  }

  function showRun(runId) {
    resultEl.hidden = false;
    runTitle.textContent = "Import started.";
    setRunChip("queued");
    if (preview && preview.files > 0) {
      runNote.textContent =
        "Copying " + preview.files +
        (preview.files === 1 ? " file" : " files") +
        " (" + formatBytes(preview.bytes) + "). Progress follows below.";
    } else {
      runNote.textContent = "Copy is queued. Progress follows below.";
    }
    runFill.style.width = "0%";
    runMeter.setAttribute("aria-valuenow", "0");
    runLink.href = "/runs/" + runId;
    runLink.textContent = "Open run";
    setStatus("Import started.", false);
    followRun(runId);
  }

  function startImport() {
    if (!startButton || startButton.disabled || submitting) {
      return;
    }
    submitting = true;
    updateConfirm();
    setStatus("Starting import…", false);
    fetch("/api/imports", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        inventory_id: Number(inventoryId),
        destination: destination.value,
        paths: Array.from(selection.keys()),
        csrf: csrf
      })
    })
      .then(function (response) {
        return parseBody(response).then(function (body) {
          return { response: response, body: body };
        });
      })
      .then(function (result) {
        if (!result.response.ok) {
          var message =
            result.response.status === 401
              ? "Session expired. Sign in again."
              : result.body.detail || "Could not start the import.";
          throw new Error(message);
        }
        showRun(result.body.run_id);
      })
      .catch(function (error) {
        submitting = false;
        setStatus(error.message, true);
        updateConfirm();
      });
  }

  if (drivePicker) {
    drivePicker.addEventListener("change", selectDrive);
  }
  if (destination) {
    destination.addEventListener("change", function () {
      invalidatePreview();
      resetStartedRun();
      updateFreeSpace();
      schedulePreview();
    });
  }
  if (startButton) {
    startButton.addEventListener("click", startImport);
  }

  var initial = selectedDriveOption();
  inventoryId = initial ? initial.getAttribute("data-inventory") || "" : "";
  updateChip(initial);
  updateFreeSpace();
  updateSummary();
  updateConfirm();
  if (initial && initial.getAttribute("data-status") === "complete" && inventoryId) {
    loadTree();
  }
})();
