/// The `instructions` the server sends in the `initialize` result and the `server/discover` result. Clients put
/// them into the agent's system prompt, so they stay short and leave details to the tool descriptions.
public enum ServerInstructions {
    public static let text = """
        Use abakus whenever a count, a sum or a date difference has to be exact, instead of working it out in your \
        head or writing a script: tallies keep counts and running sums across many turns (budgets, checkpoints \
        every N items, numbers that arrive one at a time), sum adds numbers, date_diff gives the time between two \
        dates.
        tally_create gives each tally a random suffix, so every session counts its own: use the name it returns. \
        Tallies disappear after about three days without a change. Pass shared: true only for a tally several \
        sessions are meant to add to, and leave other sessions' tallies alone unless you coordinate with them.
        Numbers may be given as strings such as "410k" or "1,234.5".
        """
}
