# Workbench, CLI, Browser, and Tips

Run tutorial commands in the window for your open database. This page explains
the code block controls and where to read the results.

## Run, copy, and edit code blocks

Each code block provides **Run** and **Copy** buttons. The controls work as follows:

- **Run** sends the commands to Workbench and opens that section. Workbench keeps
  the editor contents. The results appear at the top of the results list.
- If a block writes data, Keystrand asks for confirmation before it runs. Select
  **Don't ask again for this database** to skip later confirmations for that database.
- If you mark a database as production, Keystrand disables **Run** to prevent
  accidental changes from tutorials. You can still use **Copy**.
- If a block needs a module that the database lacks, **Run** reports the missing module.
- **Copy** copies the commands to the clipboard. To edit the commands, right-click
  the block and choose **Open in Workbench**.

Run this block to write two keys and read the counter value.

```redis:[run_confirmation=true;results=group] Run a small script
// Lines that start with // are comments and are not sent
SET tutorial:workbench:greeting "Hello from Keystrand"
3 INCR tutorial:workbench:runs
GET tutorial:workbench:runs
```

## Script syntax in Workbench

Workbench and tutorial code blocks use the same script syntax. Apply these rules:

- Write one command per line. Start a continuation line with spaces to split a
  long command across lines.
- Put a number before a command to repeat it. For example, `3 INCR key` runs
  `INCR` three times.
- Use an optional first line in square brackets to set script options, such as
  `[results=group;mode=raw]`.

The script options control results and batching as follows:

- `results=group` shows all replies in one entry.
- `results=silent` shows a summary and any failed commands.
- `mode=raw` shows strings without escaping bytes outside printable ASCII.
- `pipeline=10` sends commands in batches of ten.

```redis Change how results are shown
[results=group;mode=raw]
GET tutorial:workbench:greeting
STRLEN tutorial:workbench:greeting
```

Workbench can show search replies as tables or query plans. It can also show
time series replies as charts and geo replies as maps. Supported search commands
include `FT.SEARCH`, `FT.INFO`, `FT.EXPLAIN`, and `FT.PROFILE`. Use a result's
view menu to switch between a visualization and the plain reply.

## Read keys in the Browser

Every tutorial key starts with `tutorial:`. Open the Browser. Filter by
`tutorial:*` to list the keys, their types, and their time to live (TTL).
The tree view groups key names by the parts separated by `:`. Use the Browser
to edit values.

## Use the CLI for individual commands

To open the CLI, use the **View** menu or press Control-Backquote. The CLI
provides an interactive prompt with completion and history, like `redis-cli`.
Use it for individual commands, such as `TTL tutorial:workbench:greeting`.
Workbench keeps longer scripts and their results.

## Read database tips

The inspector's **Tips** pane checks the open database for possible improvements.
Tips can recommend a more compact data type or a missing index. Some tips link
to a tutorial.

## Clean up

Each tutorial ends with a cleanup block. The block uses `UNLINK` to delete only
the keys that the page creates. Tutorials never use `FLUSHDB` or `FLUSHALL`.

```redis:[run_confirmation=true] Delete this page's keys
UNLINK tutorial:workbench:greeting tutorial:workbench:runs
```

## Further reading

Use these references to continue:

- [Redis commands](https://redis.io/docs/latest/commands/)
- [Data types overview](https://redis.io/docs/latest/develop/data-types/)
- [Strings](../ds/strings.md), the first data type tutorial
