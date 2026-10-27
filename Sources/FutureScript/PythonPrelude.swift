// The script API for Python (docs/DESIGN.md, 6.4). It runs once, as the module `_etf`, when
// CPython starts. The bridge calls `load` for each script and `describe_error` for errors.
let pythonPrelude = #"""
import builtins
import difflib
import io
import json
import math
import os
import random as _random
import re
import sys
import traceback

SCRIPT_FILE = "<script>"
QUANTITIES = ("number", "percent", "currency", "temperature")
NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
SUBSCRIPTION = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)(\[t-1\])?\s*$")
OWN_KIND = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*$")


class TookTooLong(BaseException):
    """Raised in a script's thread when a call runs past its time limit."""


class ScriptMistake(Exception):
    """A mistake in how the script uses the API. Its line is the script's line that made the call."""


class _Printed(io.TextIOBase):
    """Keeps the last lines scripts print, instead of writing to the app's output."""

    def __init__(self):
        self.lines = []
        self.partial = ""

    def writable(self):
        return True

    def write(self, text):
        text = self.partial + str(text)
        *done, self.partial = text.split("\n")
        self.lines.extend(done)
        del self.lines[:-200]
        return len(text)


printed = _Printed()
sys.stdout = sys.stderr = printed


def _refuse(*args, **kwargs):
    raise PermissionError("Scripts in Edit The Future can't stop the app.")


# A script mustn't be able to end the app's process.
for _name in ("_exit", "abort"):
    if hasattr(os, _name):
        setattr(os, _name, _refuse)


def _number(value):
    """A number, or text like "4.5%" (0.045, shown as a percent). Returns (value, is_percent) or None."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value), False
    if isinstance(value, str):
        text = value.strip()
        try:
            if text.endswith("%"):
                return float(text[:-1]) / 100, True
            return float(text), False
        except ValueError:
            return None
    try:
        return float(value), False
    except (TypeError, ValueError):
        return None


def _finite(value):
    return value if value is not None and math.isfinite(value) else None


def _as_number(name, value):
    if isinstance(value, float):
        return value
    if isinstance(value, bool):
        return 1.0 if value else 0.0
    if isinstance(value, int):
        try:
            return float(value)
        except OverflowError:
            return math.inf if value > 0 else -math.inf
    try:
        return float(value)
    except (TypeError, ValueError):
        shown = "None" if value is None else "a " + type(value).__name__
        raise ScriptMistake(f"s.{name} should be a number, but it's {shown}") from None


class Event:
    """An event as a script sees it: e.kind, e.slot, e.date and its fields, like e.amount."""

    __slots__ = ("kind", "slot", "date", "_fields")

    def __init__(self, data):
        self.kind = data["kind"]
        self.slot = data.get("slot")
        self.date = data.get("date")
        self._fields = {key: (math.nan if value is None else float(value)) for key, value in data.get("values", {}).items()}

    def __getattr__(self, name):
        fields = object.__getattribute__(self, "_fields")
        if name in fields:
            return fields[name]
        known = ", ".join(sorted(fields)) or "none"
        raise ScriptMistake(f"This {self.kind} event has no field called {name}. Its fields: {known}.")

    def get(self, name, default=None):
        return self._fields.get(name, default)

    def __repr__(self):
        return f"Event({self.kind!r}, {self._fields!r})"


class Time:
    """The time as a script sees it: t.index, t.year, t.date, t.events, t.random() and the rest."""

    __slots__ = ("index", "year", "month", "day", "dayOfYear", "days", "dt", "date", "events", "emit")

    def __init__(self, numbers, date, events, emit):
        (self.index, self.year, self.month, self.day, self.dayOfYear, self.days, self.dt) = numbers
        self.index = int(self.index)
        self.date = date
        self.events = events
        self.emit = emit

    @staticmethod
    def random():
        return _random.random()

    @staticmethod
    def normal(mean=0.0, sd=1.0):
        return _random.gauss(mean, sd)


class Program:
    """One script, loaded into a namespace of its own."""

    def __init__(self, source):
        self._loading = True
        self._running = False
        self._every = None
        self._timeunit = None
        self._params = []
        self._vars = []
        self._inputs = []
        self._emits = []
        self._handlers = []
        self._declared = {}
        self._emitted = []
        api = {
            "every": self.every, "timeunit": self.timeunit, "param": self.param, "init": self.init,
            "output": self.output, "input": self.input, "emits": self.emits, "on": self.on, "emit": self.emit,
        }
        namespace = {"__name__": "__etf_script__", "__builtins__": builtins, **api}
        code = compile(source, SCRIPT_FILE, "exec")
        exec(code, namespace)
        self._loading = False

        self._step = namespace.get("step")
        self._start = namespace.get("start")
        if self._step is not None and not callable(self._step):
            raise ScriptMistake("step should be a function: def step(s, t):")
        if self._start is not None and not callable(self._start):
            raise ScriptMistake("start should be a function: def start(s, t):")
        self._names = [entry["name"] for entry in self._params + self._vars]
        self._input_names = [entry["name"] for entry in self._inputs]
        self._State = self._make_state_class()

    # Declarations

    def _check_loading(self, what):
        if not self._loading:
            raise ScriptMistake(f"{what} can only be used at the top of the script, not while it runs")

    def _check_name(self, name, what):
        if not isinstance(name, str) or not NAME.match(name):
            raise ScriptMistake(f'{what} needs a name made of letters, digits and underscores, like "balance"')
        if name in self._declared:
            raise ScriptMistake(f'"{name}" is already declared')

    def _options(self, what, name, is_percent, range=None, by=None, label=None, as_=None, start=None, allow_start=False):
        result = {}
        if range is not None:
            try:
                low, high = range
            except (TypeError, ValueError):
                low = high = None
            low, high = _number(low), _number(high)
            if low is None or high is None:
                raise ScriptMistake(f'{what} "{name}": range should be two numbers, like (0, 100) or ("0%", "15%")')
            result["min"], result["max"] = _finite(low[0]), _finite(high[0])
            is_percent = is_percent or low[1] or high[1]
        if by is not None:
            step = _number(by)
            if step is None:
                raise ScriptMistake(f'{what} "{name}": by should be a number')
            result["by"] = _finite(step[0])
        if label is not None:
            if not isinstance(label, str):
                raise ScriptMistake(f'{what} "{name}": label should be text')
            result["label"] = label
        if as_ is not None:
            if as_ not in QUANTITIES:
                raise ScriptMistake(f'{what} "{name}": as_ should be "number", "percent", "currency" or "temperature"')
            result["as"] = as_
        elif is_percent:
            result["as"] = "percent"
        if start is not None:
            if not allow_start:
                raise ScriptMistake(f'{what} "{name}": start is only for outputs')
            value = _number(start)
            if value is None:
                raise ScriptMistake(f'{what} "{name}": start should be a number')
            result["start"] = value[0]
        return result

    def _value(self, what, name, value, options, is_init):
        number = _number(value)
        if number is None:
            raise ScriptMistake(f'{what} "{name}" needs a value: a number, or text like "4.5%"')
        unknown = set(options) - {"range", "by", "label", "as_"}
        if unknown:
            raise ScriptMistake(f'{what} "{name}": there\'s no option called "{sorted(unknown)[0]}". '
                                "The options are range, by, label and as_.")
        entry = {"name": name, "value": _finite(number[0]), "isInit": is_init}
        entry.update(self._options(what, name, number[1], **options))
        self._declared[name] = what
        return entry

    def every(self, text):
        self._check_loading("every")
        if not isinstance(text, str):
            raise ScriptMistake('every needs text, like every("1 month")')
        self._every = text

    def timeunit(self, text):
        self._check_loading("timeunit")
        if not isinstance(text, str):
            raise ScriptMistake('timeunit needs text, like timeunit("year")')
        self._timeunit = text

    def param(self, name, value, **options):
        self._check_loading("param")
        self._check_name(name, "param")
        entry = self._value("param", name, value, options, None)
        del entry["isInit"]
        self._params.append(entry)

    def init(self, name, value, **options):
        self._check_loading("init")
        self._check_name(name, "init")
        self._vars.append(self._value("init", name, value, options, True))

    def output(self, name, **options):
        self._check_loading("output")
        self._check_name(name, "output")
        unknown = set(options) - {"range", "by", "label", "as_", "start"}
        if unknown:
            raise ScriptMistake(f'output "{name}": there\'s no option called "{sorted(unknown)[0]}". '
                                "The options are range, by, label, as_ and start.")
        read = self._options("output", name, False, allow_start=True, **options)
        entry = {"name": name, "value": _finite(read.pop("start", 0.0)), "isInit": False, **read}
        self._declared[name] = "output"
        self._vars.append(entry)

    def input(self, name, reference):
        self._check_loading("input")
        self._check_name(name, "input")
        if not isinstance(reference, str):
            raise ScriptMistake(f'input "{name}" needs another slot\'s value to read, like input("temp", "Climate.temp")')
        self._declared[name] = "input"
        self._inputs.append({"name": name, "ref": reference})

    def emits(self, *kinds):
        self._check_loading("emits")
        for kind in kinds:
            if not isinstance(kind, str) or not NAME.match(kind):
                raise ScriptMistake('emits needs event kinds made of letters, digits and underscores, like emits("Millionaire")')
            if kind not in self._emits:
                self._emits.append(kind)

    def on(self, kind, handler=None):
        self._check_loading("on")
        if not isinstance(kind, str):
            raise ScriptMistake('on needs an event kind, like @on("deposit")')
        match = SUBSCRIPTION.match(kind)
        if match:
            slot, event_kind = match.group(1), match.group(2)
        else:
            own = OWN_KIND.match(kind)
            if not own:
                raise ScriptMistake(f'on "{kind}": write an event kind like "deposit", or another slot\'s like "FireRisk.OverCapacity"')
            slot, event_kind = None, own.group(1)

        def register(function):
            if not callable(function):
                raise ScriptMistake(f'on("{kind}") needs a function, like def handler(s, e, t):')
            self._handlers.append((kind, event_kind, slot, function))
            return function

        return register(handler) if handler is not None else register

    def emit(self, kind, fields=None, **more):
        if not self._running:
            raise ScriptMistake("emit can only be used while the script runs: in step or an on handler")
        if kind not in self._emits:
            raise ScriptMistake(f'declare "{kind}" at the top with emits("{kind}") before sending it')
        values = dict(fields or {}, **more)
        for key, value in values.items():
            if not isinstance(key, str) or _number(value) is None or isinstance(value, str):
                raise ScriptMistake('emit\'s fields should be names with numbers, like emit("Paid", amount=500)')
            values[key] = _finite(float(value))
        self._emitted.append({"kind": kind, "values": values})

    # Running

    def _suggestion(self, name):
        close = difflib.get_close_matches(name, list(self._declared), n=1)
        return f" Did you mean s.{close[0]}?" if close else ""

    def _make_state_class(self):
        writable = frozenset(self._names)
        inputs = frozenset(self._input_names)
        program = self

        def __setattr__(state, name, value):
            if name in writable:
                object.__setattr__(state, name, value)
            elif name in inputs:
                raise ScriptMistake(f"s.{name} is an input from another slot, so the script can't change it")
            else:
                raise ScriptMistake(f"s.{name} isn't declared. Declare it with init or output, or use a local variable."
                                    + program._suggestion(name))

        def __getattr__(state, name):
            raise ScriptMistake(f"s.{name} isn't declared." + program._suggestion(name))

        def __repr__(state):
            shown = ", ".join(f"{name}={getattr(state, name)!r}" for name in program._names + program._input_names)
            return f"State({shown})"

        slots = tuple(self._names) + tuple(self._input_names)
        return type("State", (), {"__slots__": slots, "__setattr__": __setattr__, "__getattr__": __getattr__,
                                  "__repr__": __repr__})

    def describe(self):
        return json.dumps({
            "every": self._every, "timeunit": self._timeunit,
            "params": self._params, "vars": self._vars, "inputs": self._inputs, "emits": self._emits,
            "handlers": [handler[0] for handler in self._handlers],
            "hasStep": self._step is not None, "hasStart": self._start is not None,
        })

    def call(self, is_step, values, inputs, numbers, date, seed, index, events_json, seconds):
        global time_limit
        time_limit = seconds
        state = self._State.__new__(self._State)
        set_slot = object.__setattr__
        for name, value in zip(self._names, values):
            set_slot(state, name, value)
        for name, value in zip(self._input_names, inputs):
            set_slot(state, name, value)
        events = [Event(item) for item in json.loads(events_json)] if events_json else []
        t = Time(numbers, date, events, self.emit)
        _random.seed((seed << 64) | (index & 0xFFFFFFFFFFFFFFFF))
        self._emitted = []
        if is_step:
            self._running = True
            try:
                if self._step is not None:
                    self._step(state, t)
                for event in events:
                    for _, kind, slot, handler in self._handlers:
                        if kind == event.kind and slot == event.slot:
                            handler(state, event, t)
            finally:
                self._running = False
        else:
            self._start(state, t)
        result = [_as_number(name, getattr(state, name)) for name in self._names]
        sent = json.dumps(self._emitted) if self._emitted else None
        return result, sent


time_limit = 0.0
_library_paths = []


def load(source, library_paths, seconds):
    """Loads a script. Library modules are imported afresh for each script, so scripts don't share them.
    The bridge loads one script at a time, since sys.path and sys.modules are shared by every thread."""
    global time_limit
    time_limit = seconds
    paths = [path for path in library_paths.split("\n") if path]
    # A new list, not a change to the old one: an import running on another thread may be part-way
    # through the old list, and taking an entry out of it would make that import skip the next one.
    sys.path = paths + [path for path in sys.path if path not in _library_paths and path not in paths]
    _library_paths[:] = paths
    for name, module in list(sys.modules.items()):
        location = getattr(module, "__file__", None) or ""
        if any(location.startswith(path.rstrip("/") + "/") for path in paths):
            del sys.modules[name]
    return Program(source)


def describe_error(error):
    """An error as JSON for the app: its message, and the script's line when there is one."""
    if isinstance(error, SyntaxError) and error.filename == SCRIPT_FILE:
        return json.dumps({"message": error.msg, "line": error.lineno})
    line = None
    frame = error.__traceback__
    while frame is not None:
        if frame.tb_frame.f_code.co_filename == SCRIPT_FILE:
            line = frame.tb_lineno
        frame = frame.tb_next
    if isinstance(error, ScriptMistake):
        message = str(error)
    elif isinstance(error, TookTooLong):
        message = f"took longer than {time_limit:g} seconds. Is there an endless loop?"
    elif isinstance(error, ModuleNotFoundError):
        message = f"There's no Python module called '{error.name}'. Libraries go in the Libraries folder."
    else:
        message = "".join(traceback.format_exception_only(error)).strip()
    return json.dumps({"message": message, "line": line})
"""#
