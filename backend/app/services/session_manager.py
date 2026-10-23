"""
Tracks active navigation sessions (one per connected mobile client).
Keeps per-session frame counters and a fresh DecisionEngine instance so
different users' obstacle-announcement cooldowns don't interfere.
"""
from typing import Dict
import uuid

from app.services.decision_engine import DecisionEngine


class Session:
    def __init__(self, session_id: str):
        self.session_id = session_id
        self.frame_count = 0
        self.decision_engine = DecisionEngine()


class SessionManager:
    def __init__(self):
        self._sessions: Dict[str, Session] = {}

    def create(self) -> Session:
        session_id = str(uuid.uuid4())
        session = Session(session_id)
        self._sessions[session_id] = session
        return session

    def get_or_create(self, session_id: str) -> Session:
        if session_id not in self._sessions:
            self._sessions[session_id] = Session(session_id)
        return self._sessions[session_id]

    def remove(self, session_id: str):
        self._sessions.pop(session_id, None)


session_manager = SessionManager()
