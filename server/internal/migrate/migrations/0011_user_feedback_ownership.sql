-- Only authenticated feedback is shown in the personal console. Public contact
-- emails are not ownership proofs and must not grant access to older messages.
ALTER TABLE feedback_messages ADD COLUMN IF NOT EXISTS user_id uuid REFERENCES users(id) ON DELETE CASCADE;
CREATE INDEX IF NOT EXISTS feedback_messages_user_recent ON feedback_messages(user_id,created_at DESC) WHERE user_id IS NOT NULL;
