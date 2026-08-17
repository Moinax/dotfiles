import { showHUD, showToast, Toast } from "@vicinae/api";
import { useCallback, useEffect, useRef, useState } from "react";

/** Message for a Toast, without leaking a stack trace into the UI. */
export function describeError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/**
 * Load a list into state, reporting failure as a Toast.
 *
 * Every command here opens by reading something that can fail — sinks, windows,
 * outputs, layouts, browsers, projects — and the shape never varies: hold rows
 * and a loading flag, toast on failure, clear the flag either way. It was
 * written out eight times before this existed, in two spellings that had
 * already drifted (half exposed a refresh handle, half did not), which is the
 * real cost: a change to the convention meant finding all eight.
 *
 * `load` is held in a ref rather than listed as a dependency so that callers
 * can pass an inline arrow without `refresh` changing identity on every render
 * — which the effect below would turn into a reload loop.
 */
export function useLoader<T>(load: () => Promise<T[]>, errorTitle: string) {
  const [rows, setRows] = useState<T[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const loadRef = useRef(load);
  loadRef.current = load;

  const refresh = useCallback(async () => {
    try {
      setRows(await loadRef.current());
    } catch (error) {
      await showToast({ style: Toast.Style.Failure, title: errorTitle, message: describeError(error) });
    } finally {
      setIsLoading(false);
    }
  }, [errorTitle]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  return { rows, isLoading, refresh };
}

/**
 * Build the "act, re-read, say so" handler these lists share.
 *
 * Unlike `closeAfter`, this keeps the launcher open for repeated actions such
 * as closing several windows or toggling several monitors. Single-choice
 * commands such as audio output and keyboard layout use `closeAfter` instead.
 *
 * `settleMs` exists for the compositor, which retires a window slightly after
 * `closewindow` returns — re-reading immediately would list the row that was
 * just closed.
 */
export function actionRunner(refresh: () => Promise<void>, settleMs = 0) {
  return (label: string, run: () => Promise<unknown>) =>
    async () => {
      try {
        await run();
        if (settleMs) await new Promise((resolve) => setTimeout(resolve, settleMs));
        await refresh();
        await showToast({ style: Toast.Style.Success, title: label });
      } catch (error) {
        await showToast({ style: Toast.Style.Failure, title: `${label} failed`, message: describeError(error) });
      }
    };
}

/**
 * Wrap a launch action so success closes the launcher and failure does not.
 *
 * This is the behaviour rofi could not have. A rofi window is destroyed the
 * instant Enter is pressed, so a script that then failed had nowhere to say so
 * and had to fall back to notify-send — which is why every one of these scripts
 * carries a `fail()` helper that fires a critical notification. Here the window
 * is still up when the command returns: on success it closes with a HUD, and on
 * failure it stays open with the error in a Toast and the list still on screen,
 * so the next attempt is one keypress away instead of a re-launch.
 */
export function closeAfter(run: () => Promise<unknown>, hud: string): () => Promise<void> {
  return async () => {
    try {
      await run();
      await showHUD(hud);
    } catch (error) {
      await showToast({ style: Toast.Style.Failure, title: "Launch failed", message: describeError(error) });
    }
  };
}

/**
 * Same, for a launch slow enough to need a progress Toast.
 *
 * `run` is handed a reporter it calls as it moves through its steps; each call
 * retitles the live Toast. The window is deliberately kept open for the whole
 * sequence — creating a worktree runs a fetch, a checkout and the wt hooks, and
 * watching those go by is the point.
 */
export function closeAfterProgress(
  run: (report: (step: string) => void) => Promise<unknown>,
  opts: { start: string; hud: string },
): () => Promise<void> {
  return async () => {
    const toast = await showToast({ style: Toast.Style.Animated, title: opts.start });
    try {
      await run((step) => {
        toast.title = step;
        void toast.update();
      });
      await toast.hide();
      await showHUD(opts.hud);
    } catch (error) {
      toast.style = Toast.Style.Failure;
      toast.title = "Launch failed";
      toast.message = describeError(error);
      await toast.update();
    }
  };
}
