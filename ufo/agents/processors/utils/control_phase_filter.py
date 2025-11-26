# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

"""
Control Phase Filter for filtering controls based on task phase.

This module provides functionality to filter out certain controls
based on the current task phase (e.g., exclude minimize/close buttons
during random clicking phase).
"""

import logging
from typing import Dict, List, Optional

from ufo.agents.processors.schemas.target import TargetInfo
from ufo.agents.processors.utils.timer_manager import TaskPhase

logger = logging.getLogger(__name__)


class ControlPhaseFilter:
    """
    Filters controls based on the current task phase.
    
    Features:
    - Exclude minimize/close buttons during random clicking phase
    - Allow all controls during close app phase
    - Filter based on control names and types
    """
    
    # Keywords that indicate window chrome controls (minimize, maximize, close)
    WINDOW_CHROME_KEYWORDS = [
        "minimize", "maximize", "close", "restore",
        "min", "max", "×", "✕", "x button", "x",
        "close button", "minimize button", "maximize button"
    ]
    
    # Control types that are typically window chrome
    WINDOW_CHROME_TYPES = [
        "Button",  # Window control buttons
    ]
    
    # Common automation IDs for window controls
    WINDOW_CHROME_AUTOMATION_IDS = [
        "Minimize", "Maximize", "Close", "Restore"
    ]
    
    def __init__(self):
        """Initialize the control phase filter."""
        self.logger = logging.getLogger(f"{__name__}.ControlPhaseFilter")
    
    def filter_controls(
        self,
        controls: List[TargetInfo],
        phase: Optional[TaskPhase] = None
    ) -> List[TargetInfo]:
        """
        Filter controls based on the current task phase.
        
        :param controls: List of TargetInfo objects to filter
        :param phase: Current task phase (None means normal phase)
        :return: Filtered list of TargetInfo objects
        """
        if phase is None or phase == TaskPhase.NORMAL:
            return controls
        
        if phase == TaskPhase.RANDOM_CLICKING:
            return self._filter_for_random_clicking(controls)
        elif phase == TaskPhase.CLOSE_APP:
            return self._filter_for_close_app(controls)
        elif phase == TaskPhase.TIMED_ACTION:
            # For timed actions, allow all controls
            return controls
        
        return controls
    
    def _filter_for_random_clicking(self, controls: List[TargetInfo]) -> List[TargetInfo]:
        """
        Filter controls for random clicking phase.
        Excludes minimize, maximize, and close buttons.
        
        :param controls: List of TargetInfo objects
        :return: Filtered list excluding window chrome controls
        """
        filtered = []
        excluded_count = 0
        
        for control in controls:
            if self._is_window_chrome_control(control):
                excluded_count += 1
                self.logger.debug(
                    f"Excluding window chrome control: {control.name} "
                    f"(type: {control.type})"
                )
                continue
            filtered.append(control)
        
        if excluded_count > 0:
            self.logger.info(
                f"Filtered out {excluded_count} window chrome controls "
                f"during random clicking phase"
            )
        
        return filtered
    
    def _filter_for_close_app(self, controls: List[TargetInfo]) -> List[TargetInfo]:
        """
        Filter controls for close app phase.
        Allows all controls, including close buttons.
        
        :param controls: List of TargetInfo objects
        :return: All controls (no filtering)
        """
        # During close app phase, we want to allow all controls including close buttons
        return controls
    
    def _is_window_chrome_control(self, control: TargetInfo) -> bool:
        """
        Check if a control is a window chrome control (minimize, maximize, close).
        
        :param control: TargetInfo object to check
        :return: True if the control is window chrome, False otherwise
        """
        control_name_lower = (control.name or "").lower()
        control_type = control.type or ""
        
        # Check if control name contains window chrome keywords
        for keyword in self.WINDOW_CHROME_KEYWORDS:
            if keyword in control_name_lower:
                return True
        
        # Check automation ID if available (some controls have automation_id in the name)
        # This is a fallback for controls that might not have descriptive names
        if hasattr(control, 'automation_id') and control.automation_id:
            automation_id_lower = control.automation_id.lower()
            for chrome_id in self.WINDOW_CHROME_AUTOMATION_IDS:
                if chrome_id.lower() in automation_id_lower:
                    return True
        
        # Check if control is a small button in the top-right area
        # Window controls are typically small (less than 50x50 pixels)
        # and positioned in the top-right corner
        if control.rect:
            left, top, right, bottom = control.rect
            width = right - left
            height = bottom - top
            
            # Window controls are typically small buttons
            if width < 50 and height < 50 and control_type == "Button":
                # Additional heuristic: if it's a very small button with no text
                # and positioned near the top-right, it might be a window control
                # But we'll be conservative and only exclude if name matches
                pass
        
        return False
    
    def filter_control_dict(
        self,
        control_dict: Dict[str, TargetInfo],
        phase: Optional[TaskPhase] = None
    ) -> Dict[str, TargetInfo]:
        """
        Filter a dictionary of controls based on the current task phase.
        
        :param control_dict: Dictionary mapping control IDs to TargetInfo objects
        :param phase: Current task phase (None means normal phase)
        :return: Filtered dictionary
        """
        filtered_controls = self.filter_controls(list(control_dict.values()), phase)
        return {control.id: control for control in filtered_controls if control.id}

