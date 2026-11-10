from collections.abc import Awaitable, Callable

from langchain_core.tools import StructuredTool
from pydantic import BaseModel, Field


class GetWhatUserIsSeeingInput(BaseModel):
    prompt: str = Field(
        default="Describe what the user sees through the Quest headset camera and answer in the user's language.",
        description=(
            "Istruzione breve per il modello vision. Deve includere cosa osservare nello snapshot "
            "e come collegarlo alla domanda dell'utente."
        ),
    )


SnapshotRequester = Callable[[str], Awaitable[dict]]


def create_get_what_user_is_seeing_tool(request_snapshot: SnapshotRequester) -> StructuredTool:
    async def get_what_user_is_seeing(prompt: str) -> dict:
        """Capture the user's current Quest camera view for XR visual questions.

        Use this tool when the user asks what they are seeing, what is in front of
        them, to read visible text, to identify a real object, or to describe the
        physical room. The tool captures exactly one snapshot on demand; it does
        not start continuous video. The result contains a JPEG image encoded as
        base64 plus XR metadata such as active demo, runtime time and scene
        context. After calling it, the assistant must answer using the returned
        image and metadata instead of claiming it cannot see.
        """
        return await request_snapshot(prompt)

    return StructuredTool.from_function(
        coroutine=get_what_user_is_seeing,
        name="get_what_user_is_seeing",
        description=(
            "Capture one current Quest camera snapshot when a user asks visual questions "
            "about what they are seeing, objects in front of them, visible text or the physical room. "
            "Returns image_jpeg_base64 and XR metadata. Do not use for generic chat, time/date, "
            "or questions answerable from existing scene context."
        ),
        args_schema=GetWhatUserIsSeeingInput,
    )
