import errno
import fcntl
from datetime import datetime, timezone
from email.utils import format_datetime
import os
from pathlib import Path
import pty
import re
import shlex
import struct
import subprocess
import sys
import tempfile
import termios
import textwrap
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "scarica_zanzara.sh"


class DownloaderTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="zanzara-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.output = self.root / "podcasts"
        self.requests = self.root / "requests"
        self.feed = self.root / "feed.xml"
        self.history = self.output / "zanzara_feed_history.tsv"
        self.script = self.root / "scarica_zanzara.sh"
        source = SOURCE.read_text()
        source = source.replace(
            'OUT_DIR="/mnt/user/Multimedia/Podcasts/La Zanzara"',
            f'OUT_DIR="{self.output}"',
        ).replace('START_DATE="2026-01-01"', 'START_DATE="2025-12-29"')
        self.script.write_text(source)
        self.env = os.environ.copy()
        self.env.update(
            PATH=str(self.bin) + os.pathsep + self.env["PATH"],
            LC_ALL="C",
            TERM="xterm",
            TEST_REQUESTS=str(self.requests),
            TEST_OUTPUT=str(self.output),
            TEST_FEED=str(self.feed),
        )
        self.python_tool(
            "date",
            """
            from datetime import date, datetime, timedelta
            from email.utils import parsedate_to_datetime
            import sys

            args = sys.argv[1:]
            if args[0] == "-d":
                value, fmt = args[1], args[2]
                try:
                    if "," in value:
                        result = parsedate_to_datetime(value)
                    else:
                        parts = value.split()
                        day = date.fromisoformat(parts[0])
                        if len(parts) == 3:
                            day += timedelta(days=int(parts[1]))
                        result = datetime.combine(day, datetime.min.time())
                except ValueError:
                    sys.exit(1)
            else:
                result, fmt = datetime(2026, 1, 8), args[0]
            print(result.strftime(fmt[1:].replace("%F", "%Y-%m-%d")))
            """,
        )
        self.python_tool(
            "wget",
            """
            import os
            from pathlib import Path
            import sys

            output = next(arg.split("=", 1)[1] for arg in sys.argv
                          if arg.startswith("--output-document="))
            url = sys.argv[-1]
            if url.endswith("/lazanzara.xml"):
                Path(output).write_bytes(Path(os.environ["TEST_FEED"]).read_bytes())
                sys.exit(0)
            with open(os.environ["TEST_REQUESTS"], "a") as requests:
                requests.write(url + "\\n")
            if "FAIL_URL_DATE" in os.environ and os.environ["FAIL_URL_DATE"] in url:
                sys.exit(8)
            if "FAIL_URL_ERROR" in os.environ and os.environ["FAIL_URL_ERROR"] in url:
                sys.exit(4)
            Path(output).write_bytes(b"test mp3")
            """,
        )
        self.write_feed(["2026-01-06", "2026-01-08"])
        for day in ("2025-12-29", "2026-01-05"):
            path = self.output / day[:4] / f"La Zanzara - {day}.mp3"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"existing mp3")

    def write_feed(self, dates):
        items = []
        for day in dates:
            year, month, date = map(int, day.split("-"))
            pub_date = format_datetime(
                datetime(year, month, date, 12, tzinfo=timezone.utc)
            )
            items.append(
                f"<item><pubDate>{pub_date}</pubDate>"
                f'<enclosure url="https://podcast-radio24.ilsole24ore.com/'
                f'radio24_audio/{year}/{year % 100:02d}{month:02d}{date:02d}-'
                'lazanzara.mp3"/></item>'
            )
        self.feed.write_text("<rss><channel>" + "".join(items) + "</channel></rss>")

    def python_tool(self, name, body):
        path = self.bin / name
        path.write_text(
            "#!/bin/sh\nexec "
            + shlex.quote(sys.executable)
            + " -c "
            + shlex.quote(textwrap.dedent(body))
            + ' "$@"\n'
        )
        path.chmod(0o755)

    def run_script(self, *args):
        return subprocess.run(
            ["/bin/bash", str(self.script), *args],
            env=self.env,
            text=True,
            capture_output=True,
            timeout=30,
        )

    def test_year_summaries_and_historical_cache_migration(self):
        result = self.run_script("--repair-gaps")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            "Anno 2025: controllate=1, scaricate=0, presenti=1, "
            "non_disponibili=0, errori=0, da_scaricare=0.",
            result.stdout,
        )
        self.assertIn(
            "Anno 2026: controllate=3, scaricate=2, presenti=1, "
            "non_disponibili=0, errori=0, da_scaricare=0.",
            result.stdout,
        )
        self.assertIn(
            "Riepilogo totale: controllate=4, scaricate=2, presenti=2, "
            "non_disponibili=0, errori=0, da_scaricare=0.",
            result.stdout,
        )
        self.assertLess(result.stdout.index("Anno 2025:"), result.stdout.index("Anno 2026:"))
        requests = self.requests.read_text()
        self.assertIn("260106-lazanzara.mp3", requests)
        self.assertNotIn("260107-lazanzara.mp3", requests)
        history = self.history.read_text().splitlines()
        self.assertEqual(len(history), 4)
        self.assertTrue(all(len(line.split("\t")) == 3 for line in history))
        self.assertIn("2025-12-29", history[0])
        self.assertTrue(all(line.endswith("\t1") for line in history))

    def test_dry_run_counts_without_modifying_episode_files(self):
        before = {path: path.read_bytes() for path in self.output.rglob("*.mp3")}
        result = self.run_script("--repair-gaps", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "Riepilogo totale: controllate=4, scaricate=0, presenti=2, "
            "non_disponibili=0, errori=0, da_scaricare=2.",
            result.stdout,
        )
        self.assertFalse(self.requests.exists())
        self.assertEqual(
            before, {path: path.read_bytes() for path in self.output.rglob("*.mp3")}
        )
        self.assertNotIn("\033", result.stdout)

    def test_default_resumes_after_latest_episode(self):
        result = self.run_script("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Anno 2025:", result.stdout)
        self.assertIn("Anno 2026: controllate=2", result.stdout)
        self.assertIn("da_scaricare=2.", result.stdout)

    def test_unknown_prehistory_dates_are_not_retried(self):
        self.env["FAIL_URL_DATE"] = "251230-lazanzara"
        self.write_feed(["2025-12-30", "2026-01-06", "2026-01-08"])
        first = self.run_script("--repair-gaps")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertIn("non_disponibili=1", first.stdout)
        self.assertIn("2025-12-30", self.history.read_text())
        self.write_feed(["2026-01-06", "2026-01-08"])
        second = self.run_script("--repair-gaps")
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertNotIn("2025-12-30", self.history.read_text())
        requests = self.requests.read_text()
        self.assertEqual(requests.count("251230-lazanzara.mp3"), 1)

    def test_download_errors_are_reported_but_cached_feed_is_retained(self):
        self.env["FAIL_URL_ERROR"] = "260108-lazanzara"
        result = self.run_script("--repair-gaps")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Errore (4) su La Zanzara - 2026-01-08.mp3", result.stderr)
        self.assertIn("2026-01-08", self.history.read_text())
        self.assertTrue(self.history.read_text().rstrip().endswith("\t0"))

    def test_previously_downloaded_history_survives_feed_rotation(self):
        self.env["FAIL_URL_DATE"] = "260106-lazanzara"
        first = self.run_script("--repair-gaps")
        self.assertEqual(first.returncode, 0, first.stderr)
        old_episode = self.output / "2025" / "La Zanzara - 2025-12-29.mp3"
        old_episode.unlink()
        self.write_feed(["2026-01-08"])
        second = self.run_script("--repair-gaps")
        self.assertEqual(second.returncode, 0, second.stderr + second.stdout)
        self.assertTrue(old_episode.is_file())
        self.assertIn("2025-12-29", self.history.read_text())
        self.assertNotIn("2026-01-06", self.history.read_text())

    def test_tty_progress_is_year_scoped_and_does_not_wrap(self):
        master, slave = pty.openpty()
        self.addCleanup(os.close, master)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        process = subprocess.Popen(
            ["/bin/bash", str(self.script), "--repair-gaps", "--dry-run"],
            env=self.env,
            stdin=slave,
            stdout=slave,
            stderr=slave,
        )
        os.close(slave)
        try:
            output = bytearray()
            while True:
                try:
                    chunk = os.read(master, 8192)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    break
                if not chunk:
                    break
                output.extend(chunk)
            self.assertEqual(process.wait(timeout=30), 0)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
        text = output.decode()
        frames = re.findall(r"\r\033\[K([^\r\n]*)", text)
        self.assertTrue(any(frame.startswith("[RUN 2025]") for frame in frames))
        self.assertTrue(any(frame.startswith("[RUN 2026]") for frame in frames))
        self.assertTrue(all(len(frame) <= 79 for frame in frames))
        self.assertLess(text.index("Anno 2025:"), text.index("[RUN 2026]"))
        self.assertIn("[RUN 2026] 0 chk D:0 OK:0 ND:0 E:0 P:0", text)


if __name__ == "__main__":
    unittest.main()
