"""The B2 oracle service: the endpoints tests/b2_service.mojo must answer byte-for-byte like BentoML."""
import bentoml


@bentoml.service
class Oracle:
    @bentoml.api
    def echo(self, text: str) -> str:
        return text

    @bentoml.api
    def add(self, a: int, b: int) -> int:
        return a + b

    @bentoml.api
    def stats(self, values: list[float]) -> dict:
        n = len(values)
        return {"count": n, "sum": sum(values), "mean": sum(values) / n if n else None}

    @bentoml.api
    def greet(self, name: str, excited: bool = False) -> str:
        return f"Hello, {name}" + ("!" if excited else ".")

    @bentoml.api
    def boom(self) -> str:
        raise RuntimeError("kaboom")

    @bentoml.api
    def refuse(self, why: str) -> str:
        raise bentoml.exceptions.InvalidArgument(why)

    @bentoml.api
    def tag(self, text: str, n: int = 1) -> dict:
        return {"text": text, "upper": text.upper(), "repeat": [text] * n, "ok": True, "none": None}

    @bentoml.api
    def scale(self, values: list[int], k: float) -> list[float]:
        return [v * k for v in values]

    @bentoml.api
    def deny(self) -> str:
        raise bentoml.exceptions.BentoMLException("no", error_code=__import__("http").HTTPStatus.FORBIDDEN)

    @bentoml.api
    def missing(self, what: str) -> str:
        raise bentoml.exceptions.NotFound(what)

    @bentoml.api
    def unavailable(self) -> str:
        raise bentoml.exceptions.BentoMLException("later", error_code=__import__("http").HTTPStatus.SERVICE_UNAVAILABLE)
