///| Version types for eg-walker CRDT

///|

///| We use plain Int for LV (Local Version) and String for AgentId

///| to avoid MoonBit type alias complications

///|
/// Local Version - monotonic counter for operations
pub type LV = Int

///|
/// Agent ID - identifies a replica
pub type AgentId = String

///|
/// Raw Version - operation identifier scoped to a replica.
///
/// The decoder requires a non-empty agent and non-negative sequence. Replica
/// uniqueness remains a deployment and protocol responsibility.
pub struct RawVersion {
  agent : String
  seq : Int
} derive(Eq, Compare, Debug, ToJson)

///|
pub impl @json.FromJson for RawVersion with fn from_json(json, path) {
  match json {
    Json::Object(m) => {
      let agent_path = path.add_key("agent")
      let seq_path = path.add_key("seq")
      let agent : String = @json.from_json(
        m.get("agent").unwrap_or(Json::null()),
        path=agent_path,
      )
      let seq : Int = @json.from_json(
        m.get("seq").unwrap_or(Json::null()),
        path=seq_path,
      )
      if agent.is_empty() {
        raise @json.JsonDecodeError(
          (agent_path, "RawVersion agent must not be empty"),
        )
      }
      if seq < 0 {
        raise @json.JsonDecodeError(
          (seq_path, "RawVersion seq must be non-negative"),
        )
      }
      { agent, seq }
    }
    _ => raise @json.JsonDecodeError((path, "expected RawVersion object"))
  }
}

///|
pub impl Show for RawVersion with fn output(self, logger) {
  logger.write_string(@debug.to_string(self))
}

///|
/// Create a new RawVersion
pub fn RawVersion::new(agent : String, seq : Int) -> RawVersion {
  { agent, seq }
}

///|
/// Convert RawVersion to string representation
pub fn RawVersion::to_string(self : RawVersion) -> String {
  "\{self.agent}:\{self.seq}"
}

///|
/// Implement Hash for RawVersion
pub impl Hash for RawVersion with fn hash(self) {
  self.agent.hash() + self.seq.hash() * 31
}

///|
/// Implement Hash for RawVersion with hash_combine
pub impl Hash for RawVersion with fn hash_combine(self, hasher) {
  hasher.combine_string(self.agent)
  hasher.combine_int(self.seq)
}
