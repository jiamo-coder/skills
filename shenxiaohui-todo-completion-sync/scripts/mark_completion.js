#!/usr/bin/env node

const fs = require("fs");

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token.startsWith("--")) {
      throw new Error(`Unexpected argument: ${token}`);
    }
    const key = token.slice(2);
    const next = argv[i + 1];
    if (!next || next.startsWith("--")) {
      args[key] = "";
      continue;
    }
    args[key] = next;
    i += 1;
  }
  return args;
}

function shanghaiDate() {
  const formatter = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Shanghai",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  });
  return formatter.format(new Date());
}

function normalizeText(value) {
  return String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[\s\p{P}\p{S}]+/gu, "");
}

function findHeadingIndex(lines, heading) {
  return lines.findIndex((line) => line.trim() === heading);
}

function parseTaskBlocks(lines) {
  const blocks = [];
  let start = -1;

  function pushBlock(end) {
    if (start === -1) {
      return;
    }
    const blockLines = lines.slice(start, end);
    const fields = parseFields(blockLines);
    blocks.push({
      start,
      end,
      lines: blockLines,
      ...fields,
    });
    start = -1;
  }

  for (let i = 0; i < lines.length; i += 1) {
    if (/^##\s+已完成归档/.test(lines[i])) {
      pushBlock(i);
      break;
    }
    if (/^###\s+待办/.test(lines[i])) {
      pushBlock(i);
      start = i;
      continue;
    }
    if (start !== -1 && /^##\s+/.test(lines[i])) {
      pushBlock(i);
    }
  }
  pushBlock(lines.length);
  return blocks.filter((block) => block.project || block.task);
}

function parseFields(blockLines) {
  const fields = {
    project: "",
    task: "",
    status: "",
    completedAt: "",
    note: "",
  };

  for (const line of blockLines) {
    if (line.startsWith("- 项目：")) {
      fields.project = line.slice("- 项目：".length).trim();
    } else if (line.startsWith("- 事项：")) {
      fields.task = line.slice("- 事项：".length).trim();
    } else if (line.startsWith("- 状态：")) {
      fields.status = line.slice("- 状态：".length).trim();
    } else if (line.startsWith("- 完成日期：")) {
      fields.completedAt = line.slice("- 完成日期：".length).trim();
    } else if (line.startsWith("- 备注：")) {
      fields.note = line.slice("- 备注：".length).trim();
    }
  }

  return fields;
}

function parseArchiveEntries(lines) {
  const recentCompletedIndex = findHeadingIndex(lines, "### 最近完成");
  if (recentCompletedIndex === -1) {
    return [];
  }

  let sectionEnd = lines.length;
  for (let i = recentCompletedIndex + 1; i < lines.length; i += 1) {
    if (/^##\s+/.test(lines[i])) {
      sectionEnd = i;
      break;
    }
  }

  const entries = [];
  let current = null;

  for (let i = recentCompletedIndex + 1; i < sectionEnd; i += 1) {
    const line = lines[i];
    if (line.startsWith("- 项目：")) {
      if (current) {
        entries.push(current);
      }
      current = {
        start: i,
        end: i + 1,
        project: line.slice("- 项目：".length).trim(),
        task: "",
        completedAt: "",
      };
      continue;
    }
    if (!current) {
      continue;
    }
    current.end = i + 1;
    if (line.startsWith("- 事项：")) {
      current.task = line.slice("- 事项：".length).trim();
    } else if (line.startsWith("- 完成日期：")) {
      current.completedAt = line.slice("- 完成日期：".length).trim();
    }
  }

  if (current) {
    entries.push(current);
  }

  return entries;
}

function buildCompletionSummary(completionNote, evidence) {
  const note = String(completionNote || "").trim();
  const extra = String(evidence || "").trim();
  if (note && extra) {
    return `${note}；证据：${extra}`;
  }
  return note || (extra ? `证据：${extra}` : "Codex 已完成并验证通过");
}

function setOrInsertField(blockLines, prefix, value, insertAfterPrefixes) {
  const index = blockLines.findIndex((line) => line.startsWith(prefix));
  const rendered = `${prefix}${value}`;

  if (index !== -1) {
    if (blockLines[index] === rendered) {
      return false;
    }
    blockLines[index] = rendered;
    return true;
  }

  let insertAt = blockLines.length;
  for (const probe of insertAfterPrefixes) {
    const probeIndex = blockLines.findIndex((line) => line.startsWith(probe));
    if (probeIndex !== -1) {
      insertAt = probeIndex + 1;
    }
  }
  blockLines.splice(insertAt, 0, rendered);
  return true;
}

function appendCompletionToNote(blockLines, summary) {
  const noteIndex = blockLines.findIndex((line) => line.startsWith("- 备注："));
  if (noteIndex === -1) {
    blockLines.push(`- 备注：${summary}`);
    return true;
  }

  const noteLine = blockLines[noteIndex];
  if (noteLine.includes(summary)) {
    return false;
  }

  const current = noteLine.slice("- 备注：".length).trim();
  if (!current) {
    blockLines[noteIndex] = `- 备注：${summary}`;
    return true;
  }

  blockLines[noteIndex] = `- 备注：${current}；${summary}`;
  return true;
}

function upsertTaskBlock(lines, block, completedAt, summary) {
  const blockLines = [...block.lines];
  let changed = false;

  changed = setOrInsertField(blockLines, "- 状态：", "已完成 ✅", ["- 事项："]) || changed;
  changed =
    setOrInsertField(
      blockLines,
      "- 完成日期：",
      completedAt,
      ["- 状态：", "- 优先级：", "- 截止："]
    ) || changed;
  changed = appendCompletionToNote(blockLines, summary) || changed;

  if (changed) {
    lines.splice(block.start, block.end - block.start, ...blockLines);
  }

  return changed;
}

function archiveHasEntry(entries, project, task) {
  const normalizedProject = normalizeText(project);
  const normalizedTask = normalizeText(task);
  return entries.some(
    (entry) =>
      normalizeText(entry.project) === normalizedProject &&
      normalizeText(entry.task) === normalizedTask
  );
}

function appendArchiveEntry(lines, project, task, completedAt, summary) {
  const recentCompletedIndex = findHeadingIndex(lines, "### 最近完成");
  if (recentCompletedIndex === -1) {
    throw new Error("Missing `### 最近完成` section.");
  }

  let sectionEnd = lines.length;
  for (let i = recentCompletedIndex + 1; i < lines.length; i += 1) {
    if (/^##\s+/.test(lines[i])) {
      sectionEnd = i;
      break;
    }
  }

  let insertAt = sectionEnd;
  while (insertAt > recentCompletedIndex + 1 && lines[insertAt - 1] === "") {
    insertAt -= 1;
  }

  const payload = [];
  if (insertAt > recentCompletedIndex + 1) {
    payload.push("");
  }
  payload.push(`- 项目：${project}`);
  payload.push(`- 事项：${task}`);
  payload.push(`- 完成日期：${completedAt}`);
  payload.push(`- 备注：${summary}`);
  payload.push("");
  lines.splice(insertAt, 0, ...payload);
}

function buildRecentUpdateLine(completedAt, project, task, completionNote) {
  return `- ${completedAt}：Codex 同步完成「${project} / ${task}」`;
}

function appendRecentUpdate(lines, updateLine) {
  let recentUpdatesIndex = findHeadingIndex(lines, "## 最近更新");
  if (recentUpdatesIndex === -1) {
    lines.push("", "## 最近更新", updateLine);
    return true;
  }

  let sectionEnd = lines.length;
  for (let i = recentUpdatesIndex + 1; i < lines.length; i += 1) {
    if (/^##\s+/.test(lines[i])) {
      sectionEnd = i;
      break;
    }
  }

  for (let i = recentUpdatesIndex + 1; i < sectionEnd; i += 1) {
    if (lines[i] === updateLine) {
      return false;
    }
  }

  let insertAt = sectionEnd;
  while (insertAt > recentUpdatesIndex + 1 && lines[insertAt - 1] === "") {
    insertAt -= 1;
  }
  if (insertAt > recentUpdatesIndex + 1) {
    lines.splice(insertAt, 0, updateLine);
  } else {
    lines.splice(insertAt, 0, updateLine);
  }
  return true;
}

function writeIfChanged(filePath, originalLines, nextLines) {
  const original = `${originalLines.join("\n")}\n`;
  const next = `${nextLines.join("\n")}\n`;
  if (original === next) {
    return false;
  }
  fs.writeFileSync(filePath, next, "utf8");
  return true;
}

function main() {
  const args = parseArgs(process.argv);
  const todoFile = String(args["todo-file"] || "").trim();
  const project = String(args.project || "").trim();
  const task = String(args.task || "").trim();
  const completedAt = String(args["completed-at"] || "").trim() || shanghaiDate();
  const completionNote = String(args["completion-note"] || "").trim() || "Codex 已完成并验证通过";
  const evidence = String(args.evidence || "").trim();

  if (!todoFile) {
    throw new Error("Missing required argument: --todo-file");
  }
  if (!project) {
    throw new Error("Missing required argument: --project");
  }
  if (!task) {
    throw new Error("Missing required argument: --task");
  }
  if (!fs.existsSync(todoFile)) {
    throw new Error(`Todo file not found: ${todoFile}`);
  }

  const originalText = fs.readFileSync(todoFile, "utf8").replace(/\r\n/g, "\n").replace(/\s*$/, "");
  const originalLines = originalText.split("\n");
  const lines = [...originalLines];
  const summary = buildCompletionSummary(completionNote, evidence);
  const updateLine = buildRecentUpdateLine(completedAt, project, task, completionNote);

  const taskBlocks = parseTaskBlocks(lines);
  const exactMatches = taskBlocks.filter(
    (block) => block.project.trim() === project && block.task.trim() === task
  );

  let matchMode = "exact";
  let matches = exactMatches;

  if (matches.length === 0) {
    matchMode = "normalized";
    matches = taskBlocks.filter(
      (block) =>
        normalizeText(block.project) === normalizeText(project) &&
        normalizeText(block.task) === normalizeText(task)
    );
  }

  if (matches.length > 1) {
    process.stdout.write(
      JSON.stringify(
        {
          status: "needs_disambiguation",
          match_mode: matchMode,
          candidates: matches.map((block) => ({
            heading: block.lines[0],
            project: block.project,
            task: block.task,
            status: block.status,
            completed_at: block.completedAt,
          })),
        },
        null,
        2
      )
    );
    return;
  }

  const archiveEntries = parseArchiveEntries(lines);
  const archiveExists = archiveHasEntry(archiveEntries, project, task);

  if (matches.length === 1) {
    const target = matches[0];
    const alreadyCompleted = target.status.includes("已完成");
    let changed = upsertTaskBlock(lines, target, completedAt, summary);

    const refreshedArchiveEntries = parseArchiveEntries(lines);
    if (!archiveHasEntry(refreshedArchiveEntries, project, task)) {
      appendArchiveEntry(lines, project, task, completedAt, summary);
      changed = true;
    }

    changed = appendRecentUpdate(lines, updateLine) || changed;

    const wrote = writeIfChanged(todoFile, originalLines, lines);
    if (!wrote && alreadyCompleted && archiveExists) {
      process.stdout.write(
        JSON.stringify(
          {
            status: "no_op",
            match_mode: matchMode,
            project,
            task,
          },
          null,
          2
        )
      );
      return;
    }

    process.stdout.write(
      JSON.stringify(
        {
          status: wrote || changed ? "updated_match" : "no_op",
          match_mode: matchMode,
          project,
          task,
          completed_at: completedAt,
        },
        null,
        2
      )
    );
    return;
  }

  let changed = false;
  const refreshedArchiveEntries = parseArchiveEntries(lines);
  if (!archiveHasEntry(refreshedArchiveEntries, project, task)) {
    appendArchiveEntry(lines, project, task, completedAt, summary);
    changed = true;
  }
  changed = appendRecentUpdate(lines, updateLine) || changed;

  const wrote = writeIfChanged(todoFile, originalLines, lines);
  process.stdout.write(
    JSON.stringify(
      {
        status: wrote || changed ? "archived_only" : "no_op",
        match_mode: "none",
        project,
        task,
        completed_at: completedAt,
      },
      null,
      2
    )
  );
}

try {
  main();
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exit(1);
}
