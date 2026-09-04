"""baldr.config — typed server config from env + .env + defaults.

Phase 2.7 — typed Config. Centralizes the env_str/env_int/env_bool dance
into a single struct assembled at startup. Pure sugar over `baldr.env`;
zero new deps.
"""

from .env import env_str, env_int, env_bool, load_dotenv


@fieldwise_init
struct ServerConfig(Copyable, Movable):
    """Server configuration assembled from the environment.

    Env vars (each has a default): HOST, PORT, DEBUG, WORKERS,
    MAX_BODY_BYTES, STATIC_DIR, TEMPLATE_DIR.
    """
    var host: String
    var port: Int
    var debug: Bool
    var workers: Int
    var max_body_bytes: Int
    var static_dir: String
    var template_dir: String

    @staticmethod
    def from_env() raises -> ServerConfig:
        """Read config from the process env, loading `.env` first if present
        (real env vars win by default per `load_dotenv`)."""
        _ = load_dotenv(String(".env"))
        return ServerConfig(
            host=env_str(String("HOST"), String("0.0.0.0")),
            port=env_int(String("PORT"), 8080),
            debug=env_bool(String("DEBUG"), False),
            workers=env_int(String("WORKERS"), 4),
            max_body_bytes=env_int(String("MAX_BODY_BYTES"), 10 * 1024 * 1024),
            static_dir=env_str(String("STATIC_DIR"), String("./static")),
            template_dir=env_str(String("TEMPLATE_DIR"), String("./templates")),
        )
