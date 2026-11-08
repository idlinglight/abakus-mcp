/// The `instructions` the server sends in the `initialize` result and the `server/discover` result. Clients put
/// them into the agent's system prompt, so they stay short and leave details to the tool descriptions.
public enum ServerInstructions {
    public static let text = """
        Use abakus whenever a count, a sum or a date difference has to be exact, instead of working it out in your \
        head or writing a script: tallies keep counts across many turns, sum adds numbers, date_diff gives the time \
        between two dates.
        Tallies are shared by all sessions of this user and disappear after about three days without a change. \
        To count your own work, call tally_create with unique: true and use the name it returns.
        Numbers may be given as strings such as "410k" or "1,234.5".
        """
}
