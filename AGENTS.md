Evaluate calendar UI changes with emacsclient so I can see the updated calendar in my current session.
For any changes that don't belong in the main library but are there to prototype / test with emacs client don't add it in the main library but use dev/ directory to add code there.
For issues that I report use emacsclient to inspect the state

Keep tests compatible with all CI Emacs/Org versions; Emacs 29: older Org writes the moved range as <10:30>--<11:30>, while newer uses <10:30-11:30>

When updating the README. Only add what is user relevant. Don't add any technical implementation details.

When updating CHANGELOG. Use Unreleased section to add things which are not being released. All lines should be under 80 characters and may break into sub points if more things need to be said.
For larger changelogs, splitting in Features, Bugs and possibly other sections is useful.
