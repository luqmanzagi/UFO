# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

"""
Timer Manager for time-based task execution.

This module provides functionality to track and manage time-based tasks,
such as "randomly clicking for one minute" or "press 3 for 30 seconds".
"""

import logging
import re
import time
from dataclasses import dataclass
from enum import Enum
from typing import Dict, List, Optional, Tuple

from rich.console import Console
from rich.panel import Panel
from rich.text import Text

logger = logging.getLogger(__name__)
console = Console()


class TaskPhase(Enum):
    """Enumeration of task phases."""
    NORMAL = "normal"
    RANDOM_CLICKING = "random_clicking"
    TIMED_ACTION = "timed_action"
    CLOSE_APP = "close_app"


@dataclass
class TimeConstraint:
    """Represents a time constraint for a task phase."""
    phase: TaskPhase
    duration_seconds: float
    action_description: Optional[str] = None
    start_time: Optional[float] = None
    
    def is_active(self) -> bool:
        """Check if the time constraint is currently active."""
        if self.start_time is None:
            return False
        elapsed = time.time() - self.start_time
        return elapsed < self.duration_seconds
    
    def time_remaining(self) -> float:
        """Get the remaining time in seconds."""
        if self.start_time is None:
            return self.duration_seconds
        elapsed = time.time() - self.start_time
        return max(0, self.duration_seconds - elapsed)
    
    def has_expired(self) -> bool:
        """Check if the time constraint has expired."""
        return not self.is_active()


class TimerManager:
    """
    Manages timers for time-based task execution.
    
    Features:
    - Parse time constraints from prompts
    - Track active time constraints
    - Check if time constraints are active/expired
    - Manage multiple concurrent time constraints
    """
    
    def __init__(self):
        """Initialize the timer manager."""
        self.active_constraints: Dict[TaskPhase, TimeConstraint] = {}
        self.logger = logging.getLogger(f"{__name__}.TimerManager")
    
    def parse_time_constraints(self, prompt: str) -> List[TimeConstraint]:
        """
        Parse time constraints from a prompt string.
        
        Examples:
        - "randomly clicking for one minute" -> TimeConstraint(RANDOM_CLICKING, 60)
        - "press 3 for 30 second" -> TimeConstraint(TIMED_ACTION, 30, "press 3")
        - "click for 2 minutes" -> TimeConstraint(RANDOM_CLICKING, 120)
        
        :param prompt: The prompt string to parse
        :return: List of TimeConstraint objects found in the prompt
        """
        constraints = []
        prompt_lower = prompt.lower()
        
        # Pattern to match time expressions like "for X minute(s)", "for X second(s)", etc.
        time_patterns = [
            (r'for\s+(\d+)\s+minute', 60),  # "for X minute" -> X * 60 seconds
            (r'for\s+(\d+)\s+min', 60),     # "for X min" -> X * 60 seconds
            (r'for\s+(\d+)\s+second', 1),   # "for X second" -> X seconds
            (r'for\s+(\d+)\s+sec', 1),     # "for X sec" -> X seconds
            (r'for\s+one\s+minute', 60),   # "for one minute" -> 60 seconds
            (r'for\s+a\s+minute', 60),     # "for a minute" -> 60 seconds
        ]
        
        # Pattern to match "randomly clicking" or "random clicking"
        random_click_pattern = r'(randomly\s+clicking|random\s+clicking|clicking\s+randomly)'
        
        # Pattern to match "press X" or "click X" or "hold X"
        action_pattern = r'(press|click|hold|type)\s+([^\s]+)'
        
        # Check for random clicking phase
        if re.search(random_click_pattern, prompt_lower):
            for pattern, multiplier in time_patterns:
                match = re.search(pattern, prompt_lower)
                if match:
                    if 'one' in match.group(0) or 'a ' in match.group(0):
                        duration = multiplier
                    else:
                        duration = int(match.group(1)) * multiplier
                    constraints.append(TimeConstraint(
                        phase=TaskPhase.RANDOM_CLICKING,
                        duration_seconds=duration,
                        action_description="random clicking"
                    ))
                    break
        
        # Check for specific timed actions (e.g., "press 3 for 30 seconds")
        action_match = re.search(action_pattern, prompt_lower)
        if action_match:
            action_type = action_match.group(1)
            action_target = action_match.group(2)
            
            # Find time constraint for this action
            for pattern, multiplier in time_patterns:
                time_match = re.search(pattern, prompt_lower)
                if time_match:
                    if 'one' in time_match.group(0) or 'a ' in time_match.group(0):
                        duration = multiplier
                    else:
                        duration = int(time_match.group(1)) * multiplier
                    constraints.append(TimeConstraint(
                        phase=TaskPhase.TIMED_ACTION,
                        duration_seconds=duration,
                        action_description=f"{action_type} {action_target}"
                    ))
                    break
        
        # Check for close app phase
        if re.search(r'close\s+(the\s+)?app|close\s+(the\s+)?application', prompt_lower):
            constraints.append(TimeConstraint(
                phase=TaskPhase.CLOSE_APP,
                duration_seconds=0,  # No time limit for closing
                action_description="close app"
            ))
        
        return constraints
    
    def start_constraint(self, constraint: TimeConstraint) -> None:
        """
        Start tracking a time constraint.
        
        :param constraint: The time constraint to start tracking
        """
        constraint.start_time = time.time()
        self.active_constraints[constraint.phase] = constraint
        self.logger.info(
            f"Started {constraint.phase.value} phase: "
            f"{constraint.duration_seconds}s ({constraint.action_description})"
        )
        # Print timer start to console
        timer_text = Text()
        timer_text.append("⏰ ", style="bold yellow")
        timer_text.append("Timer Started: ", style="yellow")
        timer_text.append(f"{constraint.phase.value.upper()}", style="bold cyan")
        timer_text.append(f" for {constraint.duration_seconds:.1f} seconds", style="cyan")
        if constraint.action_description:
            timer_text.append(f" ({constraint.action_description})", style="dim cyan")
        console.print(Panel(timer_text, title="[bold yellow]Timer Manager[/bold yellow]", border_style="yellow"))
    
    def get_active_phase(self) -> Optional[TaskPhase]:
        """
        Get the currently active task phase.
        
        :return: The active TaskPhase or None if no phase is active
        """
        for phase, constraint in self.active_constraints.items():
            if constraint.is_active():
                return phase
        return None
    
    def is_phase_active(self, phase: TaskPhase) -> bool:
        """
        Check if a specific phase is currently active.
        
        :param phase: The phase to check
        :return: True if the phase is active, False otherwise
        """
        constraint = self.active_constraints.get(phase)
        if constraint is None:
            return False
        return constraint.is_active()
    
    def get_time_remaining(self, phase: TaskPhase) -> float:
        """
        Get the remaining time for a specific phase.
        
        :param phase: The phase to check
        :return: Remaining time in seconds, or 0 if not active
        """
        constraint = self.active_constraints.get(phase)
        if constraint is None:
            return 0.0
        return constraint.time_remaining()
    
    def stop_constraint(self, phase: TaskPhase) -> None:
        """
        Stop tracking a time constraint.
        
        :param phase: The phase to stop tracking
        """
        if phase in self.active_constraints:
            constraint = self.active_constraints.pop(phase)
            elapsed = time.time() - constraint.start_time if constraint.start_time else 0
            self.logger.info(
                f"Stopped {phase.value} phase after {elapsed:.2f}s"
            )
            # Print timer stop to console
            timer_text = Text()
            timer_text.append("⏰ ", style="bold green")
            timer_text.append("Timer Stopped: ", style="green")
            timer_text.append(f"{phase.value.upper()}", style="bold cyan")
            timer_text.append(f" after {elapsed:.2f}s", style="cyan")
            console.print(Panel(timer_text, title="[bold green]Timer Manager[/bold green]", border_style="green"))
    
    def clear_all(self) -> None:
        """Clear all active time constraints."""
        self.active_constraints.clear()
        self.logger.info("Cleared all time constraints")
    
    def should_continue_phase(self, phase: TaskPhase) -> bool:
        """
        Check if a phase should continue based on its time constraint.
        
        :param phase: The phase to check
        :return: True if the phase should continue, False if it should stop
        """
        constraint = self.active_constraints.get(phase)
        if constraint is None:
            return False
        return constraint.is_active()

