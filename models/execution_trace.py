#!/usr/bin/env python3
"""
Open Claw - Execution Trace Model (Python Glue Code)
Model recording layer: Structured execution trace model processing and output

This module provides the data model for execution traces, including:
- Trace model definition and validation
- Step tracking and status management
- Event audit logging
- Structured JSON output
- Record persistence and querying
"""

import json
import os
import sys
import argparse
import time
from datetime import datetime, timezone
from typing import Dict, List, Any, Optional
from dataclasses import dataclass, field, asdict
from enum import Enum


class StepStatus(str, Enum):
    PENDING = "pending"
    RUNNING = "running"
    SUCCESS = "success"
    FAILED = "failed"
    SKIPPED = "skipped"


class TraceStatus(str, Enum):
    PENDING = "pending"
    RUNNING = "running"
    SUCCESS = "success"
    FAILED = "failed"


@dataclass
class AuditEvent:
    event_id: str
    timestamp: str
    event_type: str
    resource_type: str
    resource_name: str
    status: str
    details: Dict[str, str] = field(default_factory=dict)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "event_id": self.event_id,
            "timestamp": self.timestamp,
            "event_type": self.event_type,
            "resource_type": self.resource_type,
            "resource_name": self.resource_name,
            "status": self.status,
            "details": self.details
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> 'AuditEvent':
        details = data.get("details", {})
        if isinstance(details, str):
            details = cls._parse_details_string(details)
        return cls(
            event_id=data.get("event_id", ""),
            timestamp=data.get("timestamp", ""),
            event_type=data.get("event_type", ""),
            resource_type=data.get("resource_type", ""),
            resource_name=data.get("resource_name", ""),
            status=data.get("status", ""),
            details=details
        )

    @staticmethod
    def _parse_details_string(details_str: str) -> Dict[str, str]:
        result = {}
        if not details_str:
            return result
        for item in details_str.split("; "):
            if "=" in item:
                key, value = item.split("=", 1)
                result[key.strip()] = value.strip()
        return result


@dataclass
class ExecutionStep:
    step_id: str
    step_type: str
    status: StepStatus = StepStatus.PENDING
    description: str = ""
    start_time: Optional[str] = None
    end_time: Optional[str] = None
    error_message: str = ""

    def to_dict(self) -> Dict[str, Any]:
        return {
            "step_id": self.step_id,
            "step_type": self.step_type,
            "status": self.status.value if isinstance(self.status, StepStatus) else self.status,
            "description": self.description,
            "start_time": self.start_time,
            "end_time": self.end_time,
            "error_message": self.error_message
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> 'ExecutionStep':
        status = data.get("status", "pending")
        if isinstance(status, str):
            try:
                status = StepStatus(status)
            except ValueError:
                status = StepStatus.PENDING
        return cls(
            step_id=data.get("step_id", ""),
            step_type=data.get("step_type", ""),
            status=status,
            description=data.get("description", ""),
            start_time=data.get("start_time"),
            end_time=data.get("end_time"),
            error_message=data.get("error_message", "")
        )

    def get_duration_ms(self) -> Optional[float]:
        if not self.start_time or not self.end_time:
            return None
        try:
            start = datetime.fromisoformat(self.start_time.replace('Z', '+00:00'))
            end = datetime.fromisoformat(self.end_time.replace('Z', '+00:00'))
            return (end - start).total_seconds() * 1000
        except (ValueError, AttributeError):
            return None


@dataclass
class ExecutionTrace:
    trace_id: str
    version: str = "1.0.0"
    command: str = ""
    args: List[str] = field(default_factory=list)
    start_time: str = ""
    end_time: str = ""
    status: TraceStatus = TraceStatus.PENDING
    exit_code: int = 0
    context: Dict[str, str] = field(default_factory=dict)
    steps: List[ExecutionStep] = field(default_factory=list)
    events: List[AuditEvent] = field(default_factory=list)
    results: Dict[str, str] = field(default_factory=dict)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "trace_id": self.trace_id,
            "version": self.version,
            "command": self.command,
            "args": self.args,
            "start_time": self.start_time,
            "end_time": self.end_time,
            "status": self.status.value if isinstance(self.status, TraceStatus) else self.status,
            "exit_code": self.exit_code,
            "context": self.context,
            "steps": [step.to_dict() for step in self.steps],
            "events": [event.to_dict() for event in self.events],
            "results": self.results
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> 'ExecutionTrace':
        status = data.get("status", "pending")
        if isinstance(status, str):
            try:
                status = TraceStatus(status)
            except ValueError:
                status = TraceStatus.PENDING

        steps_data = data.get("steps", [])
        steps = [ExecutionStep.from_dict(s) for s in steps_data]

        events_data = data.get("events", [])
        events = [AuditEvent.from_dict(e) for e in events_data]

        return cls(
            trace_id=data.get("trace_id", ""),
            version=data.get("version", "1.0.0"),
            command=data.get("command", ""),
            args=data.get("args", []),
            start_time=data.get("start_time", ""),
            end_time=data.get("end_time", ""),
            status=status,
            exit_code=data.get("exit_code", 0),
            context=data.get("context", {}),
            steps=steps,
            events=events,
            results=data.get("results", {})
        )

    def get_duration_ms(self) -> Optional[float]:
        if not self.start_time or not self.end_time:
            return None
        try:
            start = datetime.fromisoformat(self.start_time.replace('Z', '+00:00'))
            end = datetime.fromisoformat(self.end_time.replace('Z', '+00:00'))
            return (end - start).total_seconds() * 1000
        except (ValueError, AttributeError):
            return None

    def get_success_step_count(self) -> int:
        return sum(1 for s in self.steps if s.status == StepStatus.SUCCESS)

    def get_failed_step_count(self) -> int:
        return sum(1 for s in self.steps if s.status == StepStatus.FAILED)

    def validate(self) -> List[str]:
        errors = []
        if not self.trace_id:
            errors.append("trace_id is required")
        if not self.command:
            errors.append("command is required")
        if not self.start_time:
            errors.append("start_time is required")
        step_ids = set()
        for step in self.steps:
            if step.step_id in step_ids:
                errors.append(f"Duplicate step_id: {step.step_id}")
            step_ids.add(step.step_id)
        return errors

    def get_step_by_id(self, step_id: str) -> Optional[ExecutionStep]:
        for step in self.steps:
            if step.step_id == step_id:
                return step
        return None

    def summary(self) -> Dict[str, Any]:
        return {
            "trace_id": self.trace_id,
            "command": self.command,
            "status": self.status.value if isinstance(self.status, TraceStatus) else self.status,
            "duration_ms": self.get_duration_ms(),
            "total_steps": len(self.steps),
            "success_steps": self.get_success_step_count(),
            "failed_steps": self.get_failed_step_count(),
            "total_events": len(self.events),
            "namespace": self.context.get("namespace", "default"),
            "operator": self.context.get("operator", "unknown")
        }


class TraceManager:
    def __init__(self, records_dir: str):
        self.records_dir = records_dir

    def get_date_dir(self, dt: Optional[datetime] = None) -> str:
        if dt is None:
            dt = datetime.now(timezone.utc)
        date_str = dt.strftime("%Y-%m-%d")
        return os.path.join(self.records_dir, date_str)

    def get_trace_path(self, trace_id: str) -> Optional[str]:
        if not os.path.isdir(self.records_dir):
            return None
        for root, dirs, files in os.walk(self.records_dir):
            for f in files:
                if f == f"trace_{trace_id}.json":
                    return os.path.join(root, f)
        return None

    def load_trace(self, trace_id: str) -> Optional[ExecutionTrace]:
        path = self.get_trace_path(trace_id)
        if not path or not os.path.isfile(path):
            return None
        try:
            with open(path, 'r', encoding='utf-8') as f:
                data = json.load(f)
            return ExecutionTrace.from_dict(data)
        except (json.JSONDecodeError, IOError):
            return None

    def save_trace(self, trace: ExecutionTrace) -> str:
        date_dir = self.get_date_dir()
        os.makedirs(date_dir, exist_ok=True)
        path = os.path.join(date_dir, f"trace_{trace.trace_id}.json")

        with open(path, 'w', encoding='utf-8') as f:
            json.dump(trace.to_dict(), f, indent=2, ensure_ascii=False)

        return path

    def list_traces(self, limit: int = 20, since: Optional[str] = None) -> List[ExecutionTrace]:
        traces = []

        if not os.path.isdir(self.records_dir):
            return traces

        all_files = []
        for root, dirs, files in os.walk(self.records_dir):
            for f in files:
                if f.startswith("trace_") and f.endswith(".json"):
                    filepath = os.path.join(root, f)
                    mtime = os.path.getmtime(filepath)
                    all_files.append((mtime, filepath))

        all_files.sort(key=lambda x: x[0], reverse=True)

        if since:
            try:
                since_dt = datetime.fromisoformat(since.replace('Z', '+00:00'))
                since_ts = since_dt.timestamp()
                all_files = [(t, p) for t, p in all_files if t >= since_ts]
            except ValueError:
                pass

        for _, filepath in all_files[:limit]:
            try:
                with open(filepath, 'r', encoding='utf-8') as f:
                    data = json.load(f)
                traces.append(ExecutionTrace.from_dict(data))
            except (json.JSONDecodeError, IOError):
                continue

        return traces

    def cleanup_old(self, days: int = 30) -> int:
        import time as _time
        cutoff = _time.time() - (days * 86400)
        deleted = 0

        if not os.path.isdir(self.records_dir):
            return 0

        for root, dirs, files in os.walk(self.records_dir, topdown=False):
            for f in files:
                if f.startswith("trace_") and f.endswith(".json"):
                    filepath = os.path.join(root, f)
                    try:
                        if os.path.getmtime(filepath) < cutoff:
                            os.remove(filepath)
                            deleted += 1
                    except OSError:
                        pass
            try:
                if not os.listdir(root):
                    os.rmdir(root)
            except OSError:
                pass

        return deleted


def process_trace_from_json(json_data: str, output_dir: str) -> str:
    try:
        data = json.loads(json_data)
    except json.JSONDecodeError as e:
        print(f"Error parsing JSON: {e}", file=sys.stderr)
        sys.exit(1)

    trace = ExecutionTrace.from_dict(data)

    errors = trace.validate()
    if errors:
        for err in errors:
            print(f"Validation warning: {err}", file=sys.stderr)

    manager = TraceManager(output_dir)
    path = manager.save_trace(trace)

    summary = trace.summary()
    print(f"Trace saved: {path}")
    print(f"Status: {summary['status']}")
    print(f"Duration: {summary['duration_ms']}ms" if summary['duration_ms'] else "Duration: N/A")

    return path


def main():
    parser = argparse.ArgumentParser(description="Open Claw Execution Trace Model Processor")
    parser.add_argument("--trace-id", help="Trace ID")
    parser.add_argument("--output-dir", default="./records", help="Output directory for trace records")
    parser.add_argument("--json", help="JSON trace data string")
    parser.add_argument("--input", "-i", help="Input JSON file path")
    parser.add_argument("--list", action="store_true", help="List recent traces")
    parser.add_argument("--show", help="Show details of a specific trace")
    parser.add_argument("--limit", type=int, default=20, help="Number of traces to list")
    parser.add_argument("--summary", action="store_true", help="Show summary instead of full details")
    parser.add_argument("--cleanup", type=int, metavar="DAYS", help="Clean up traces older than DAYS")
    parser.add_argument("--since", help="List traces since ISO datetime")

    args = parser.parse_args()

    manager = TraceManager(args.output_dir)

    if args.cleanup is not None:
        deleted = manager.cleanup_old(args.cleanup)
        print(f"Cleaned up {deleted} old trace records")
        return 0

    if args.list:
        traces = manager.list_traces(limit=args.limit, since=args.since)
        if args.summary:
            print(json.dumps([t.summary() for t in traces], indent=2))
        else:
            print(f"{'TRACE_ID':<28} {'COMMAND':<15} {'STATUS':<10} {'DURATION':<12} {'STEPS':<8} {'EVENTS':<8}")
            print("-" * 90)
            for t in traces:
                dur = f"{t.get_duration_ms():.0f}ms" if t.get_duration_ms() else "N/A"
                print(f"{t.trace_id:<28} {t.command:<15} {t.status.value:<10} {dur:<12} {len(t.steps):<8} {len(t.events):<8}")
        return 0

    if args.show:
        trace = manager.load_trace(args.show)
        if not trace:
            print(f"Trace not found: {args.show}", file=sys.stderr)
            return 1
        if args.summary:
            print(json.dumps(trace.summary(), indent=2))
        else:
            print(json.dumps(trace.to_dict(), indent=2))
        return 0

    if args.json:
        process_trace_from_json(args.json, args.output_dir)
        return 0

    if args.input:
        if not os.path.isfile(args.input):
            print(f"Input file not found: {args.input}", file=sys.stderr)
            return 1
        with open(args.input, 'r', encoding='utf-8') as f:
            json_data = f.read()
        process_trace_from_json(json_data, args.output_dir)
        return 0

    parser.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
