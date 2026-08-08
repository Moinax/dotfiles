import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

/**
 * Every command this extension runs goes through execFile, never a shell.
 *
 * The rofi scripts this replaces had no choice — a `-modi` script *is* a shell,
 * so every branch name and path travelled as a word that bash would re-split
 * (which is why rofi-wts had to strip whitespace out of its own result before
 * trusting it). Here arguments are passed as an argv array, so a branch called
 * `fix/it; rm -rf` is one argument and nothing else. No quoting rules to get
 * right, and no reason to sanitise anything on the way in.
 */

export class CommandError extends Error {
  constructor(
    readonly command: string,
    readonly stderr: string,
    cause: unknown,
  ) {
    // Callers surface this straight into a Toast, so the message has to read as
    // a sentence on its own: stderr first when the command bothered to print
    // one, the spawn failure otherwise (ENOENT — helper not on PATH).
    const detail = stderr.trim() || (cause instanceof Error ? cause.message : String(cause));
    super(`${command}: ${detail}`);
    this.name = "CommandError";
  }
}

export type RunOptions = {
  cwd?: string;
  /** Milliseconds before the child is killed. Kept short: everything here is local. */
  timeout?: number;
};

/** Run a command and return its stdout, throwing CommandError on failure. */
export async function capture(cmd: string, args: string[] = [], opts: RunOptions = {}): Promise<string> {
  try {
    const { stdout } = await execFileAsync(cmd, args, {
      cwd: opts.cwd,
      timeout: opts.timeout ?? 15_000,
      encoding: "utf8",
      // git for-each-ref over a big repo comfortably exceeds node's 1MB default.
      maxBuffer: 16 * 1024 * 1024,
    });
    return stdout;
  } catch (error) {
    const stderr = typeof (error as { stderr?: unknown }).stderr === "string" ? (error as { stderr: string }).stderr : "";
    throw new CommandError([cmd, ...args].join(" "), stderr, error);
  }
}

/** Run a command and return stdout split into non-empty trimmed lines. */
export async function captureLines(cmd: string, args: string[] = [], opts: RunOptions = {}): Promise<string[]> {
  const stdout = await capture(cmd, args, opts);
  return stdout.split("\n").map((line) => line.trim()).filter((line) => line.length > 0);
}

/**
 * Fire a launcher and forget it.
 *
 * `dev` and `wtstart-launch` both hand off to a detached `dev-herdr` and exit,
 * so there is nothing to wait for — but `capture` would wait anyway. execFile
 * resolves on stdout EOF, not on exit, and a grandchild that inherited the pipe
 * holds it open for as long as the workspace lives. That is the whole reason
 * for this second path: stdio is dropped on the floor so no descriptor is
 * shared, detached puts the child in its own process group, and unref lets the
 * extension host exit without it.
 *
 * Resolves once the child is spawned. A failure *after* spawn is invisible
 * here by construction — callers must validate before getting this far.
 */
export function spawnDetached(cmd: string, args: string[], opts: RunOptions = {}): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { cwd: opts.cwd, detached: true, stdio: "ignore" });
    child.once("error", (error) => reject(new CommandError([cmd, ...args].join(" "), "", error)));
    child.once("spawn", () => {
      child.unref();
      resolve();
    });
  });
}
