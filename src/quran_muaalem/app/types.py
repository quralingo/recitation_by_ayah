from typing import (
    Optional,
    get_origin,
    get_args,
    Union,
    Literal,
)


from fastapi import Form
from pydantic import BaseModel, Field
from inspect import Parameter, Signature

from quran_transcript import SifaOutput
from quran_transcript.phonetics.moshaf_attributes import MoshafAttributes

DEFAULT_MOSHAF = MoshafAttributes(
    rewaya="hafs",
    madd_monfasel_len=4,
    madd_mottasel_len=4,
    madd_mottasel_waqf=4,
    madd_aared_len=4,
)


class PhonemesSearchSpanApp(BaseModel):
    """Represents a position in the Uthmani Quran text (App version)."""

    sura_idx: int = Field(description="Sura number (1-114)")
    aya_idx: int = Field(description="Aya number within the sura")
    uthmani_word_idx: int = Field(
        description="0-based index of the word within the aya"
    )
    uthmani_char_idx: int = Field(description="0-based character index within the word")
    phonemes_idx: int = Field(description="0-based index in the phoneme sequence")


class TajweedRuleNameApp(BaseModel):
    """Localized name for Tajweed rules (extensible for more languages in future)."""

    ar: str = Field(description="Arabic name")
    en: str = Field(description="English name")


class TajweedRuleApp(BaseModel):
    """Represents a Tajweed rule (single model for all rule types)."""

    name: TajweedRuleNameApp = Field(description="Localized name of the Tajweed rule")
    golden_len: int = Field(description="Expected length for count-based rules")
    correctness_type: Literal["match", "count"] = Field(
        description="Type of correctness check"
    )
    tag: Optional[str] = Field(default=None, description="Rule-specific tag")


class SearchResultResponse(BaseModel):
    """Result of a phonetic search match."""

    start: PhonemesSearchSpanApp = Field(description="Start position of the match")
    end: PhonemesSearchSpanApp = Field(
        description="End position of the match (exclusive)"
    )
    uthmani_text: str = Field(description="Matched Uthmani text snippet")


class SearchResponse(BaseModel):
    """Response from the search/voice endpoint."""

    phonemes: str = Field(description="Phonetic representation of the input audio")
    results: list[SearchResultResponse] = Field(description="List of search results")
    message: str | None = Field(
        default=None, description="Optional message (e.g., no results found)"
    )


class TranscriptResponse(BaseModel):
    """Response from the /transcript endpoint."""

    phonemes: str = Field(description="Phonetic transcription from audio")
    sifat: list[SifaOutput] | None = Field(
        default=None,
        description="Sifa (attributes) - currently not implemented, always None",
    )


class TajweedRuleInfo(BaseModel):
    """A tajweed rule attached to a word-level error."""

    name_ar: str = Field(description="Arabic name of the rule")
    name_en: str = Field(description="English name of the rule")
    expected_count: Optional[int] = Field(
        default=None,
        description="How many counts the rule requires (e.g. 4 for a 4-count madd)",
    )
    said_count: Optional[int] = Field(
        default=None, description="How many counts the reciter actually said"
    )
    tag: Optional[str] = Field(
        default=None, description="Rule sub-type tag (e.g. 'alif', 'waw')"
    )


class WordError(BaseModel):
    """A single error on a specific word in the verse."""

    error_type: Literal["tajweed", "pronunciation", "tashkeel"] = Field(
        description=(
            "tajweed: a tajweed rule was violated (see tajweed_rules), "
            "pronunciation: wrong consonant or sound, "
            "tashkeel: wrong short vowel (haraka)"
        )
    )
    speech_error: Literal["insert", "delete", "replace"] = Field(
        description=(
            "insert: an extra sound was added, "
            "delete: a required sound was omitted, "
            "replace: the correct sound was replaced with a wrong one"
        )
    )
    expected: str = Field(description="The correct phonemes expected at this position")
    said: str = Field(
        description="The phonemes the reciter actually produced (empty for delete errors)"
    )
    tajweed_rules: Optional[list[TajweedRuleInfo]] = Field(
        default=None,
        description="Violated tajweed rules — only populated for tajweed errors",
    )


class WordAnalysis(BaseModel):
    """Analysis result for a single word in the verse."""

    word: str = Field(description="Uthmani text of this word")
    word_idx: int = Field(description="0-based position of this word within the verse")
    status: Literal["correct", "error"] = Field(
        description="correct if recited without errors, error if any errors were found"
    )
    errors: list[WordError] = Field(
        description="All errors found on this word (empty list when status is correct)"
    )


class CorrectRecitationResponse(BaseModel):
    """Response from /correct-recitation — word-centric format."""

    sura_idx: int = Field(description="0-based sura index of the matched verse")
    aya_idx: int = Field(description="0-based aya index within the sura")
    uthmani_text: str = Field(description="Uthmani text of the matched verse span")
    words: list[WordAnalysis] = Field(
        description="Per-word breakdown: each word shows its status and any errors"
    )
    predicted_phonemes: str = Field(
        description="Raw phonemes transcribed from the audio (useful for debugging)"
    )
    reference_phonemes: str = Field(
        description="Correct reference phonemes for the matched span (useful for debugging)"
    )


class CorrectRecitationNoMatchResponse(BaseModel):
    """Response returned when no matching Quran span is found."""

    predicted_phonemes: str = Field(
        description="Phonetic text from audio prediction"
    )
    message: str = Field(
        description="Reason why matching failed"
    )


def convert_form_value(value: str, field_type):
    """
    Convert a raw form string to the type expected by the model.
    Handles Literal fields (e.g., Literal[2,4,6] -> int) and Optional.
    """
    # Handle Optional (Union[..., None])
    if get_origin(field_type) is Union:
        args = get_args(field_type)
        if type(None) in args and len(args) == 2:
            # Extract the non‑None type
            non_none = next(arg for arg in args if arg is not type(None))
            field_type = non_none

    # If Literal, get the type of its values (all should be the same)
    if get_origin(field_type) is Literal:
        args = get_args(field_type)
        if args:
            target_type = type(args[0])
        else:
            target_type = str  # fallback (should not happen)
    else:
        target_type = field_type

    # Convert based on target type
    if target_type is int:
        return int(value)
    elif target_type is float:
        return float(value)
    # For strings, return as‑is
    return value


def correct_recitation_form_dependency(default_moshaf=DEFAULT_MOSHAF):
    """
    Generates a dependency that extracts each field of MoshafAttributes
    plus error_ratio from multipart/form‑data fields, converts the strings
    to the correct Python types, and builds a CorrectRecitationRequest.
    """
    parameters = []

    default_moshaf_fields = default_moshaf.model_dump()
    for name, field in MoshafAttributes.model_fields.items():
        default = default_moshaf_fields[name]

        # Handle Literal[int] fields specially: create a string enum for OpenAPI
        if get_origin(field.annotation) is Literal:
            # Get the allowed integer values and convert them to strings
            int_values = get_args(field.annotation)
            str_enum = [str(v) for v in int_values]

            # Use Form with enum, and set annotation to str so FastAPI shows string enum
            form_param = Form(
                str(default), description=field.description, enum=str_enum
            )
            param_annotation = str
        else:
            # For non‑Literal fields, use the original annotation and plain Form
            form_param = Form(default, description=field.description)
            param_annotation = field.annotation

        param = Parameter(
            name=name,
            kind=Parameter.KEYWORD_ONLY,
            default=form_param,
            annotation=param_annotation,
        )
        parameters.append(param)

    sig = Signature(parameters)

    def dependency(**kwargs):

        # Convert each moshaf field from string to the required type
        converted = default_moshaf.model_dump()
        for name, raw_value in kwargs.items():
            field = MoshafAttributes.model_fields[name]
            converted[name] = convert_form_value(raw_value, field.annotation)

        moshaf = MoshafAttributes(**converted)
        return moshaf

    dependency.__signature__ = sig
    dependency.__name__ = "correct_recitation_form_dependency"
    return dependency
