// SPDX-License-Identifier: AGPL-3.0-only

/// `user_version = 4`, taken verbatim from the Android Room v4 schema so that a snapshot exported by
/// one host imports into the other with identical column semantics (IOS_PORT_PROMPT §7).
enum TsuyomiSchema {
    static let version4: [String] = [
        """
        CREATE TABLE books (source_id TEXT NOT NULL, remote_book_id TEXT NOT NULL, title TEXT NOT NULL, \
        authors_json TEXT NOT NULL DEFAULT '[]', author_sort_key BLOB, cover_url TEXT, canonical_url TEXT, \
        status TEXT, remote_tags_json TEXT NOT NULL DEFAULT '[]', source_update_key TEXT, \
        has_unread_update INTEGER NOT NULL DEFAULT 0, added_at_epoch_second INTEGER NOT NULL, \
        added_at_nano INTEGER NOT NULL, metadata_updated_at_epoch_second INTEGER NOT NULL, \
        metadata_updated_at_nano INTEGER NOT NULL, PRIMARY KEY(source_id, remote_book_id))
        """,
        """
        CREATE TABLE collections (collection_id TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, \
        parent_collection_id TEXT, display_order INTEGER NOT NULL, \
        created_at_epoch_second INTEGER NOT NULL DEFAULT 0, created_at_nano INTEGER NOT NULL DEFAULT 0, \
        updated_at_epoch_second INTEGER NOT NULL DEFAULT 0, updated_at_nano INTEGER NOT NULL DEFAULT 0, \
        PRIMARY KEY(collection_id), FOREIGN KEY(parent_collection_id) REFERENCES collections(collection_id) \
        ON UPDATE NO ACTION ON DELETE SET NULL)
        """,
        "CREATE INDEX index_collections_parent_collection_id ON collections(parent_collection_id)",
        """
        CREATE TABLE library_entries (source_id TEXT NOT NULL, remote_book_id TEXT NOT NULL, \
        added_at_epoch_second INTEGER NOT NULL, added_at_nano INTEGER NOT NULL, rating INTEGER, \
        read_later INTEGER NOT NULL DEFAULT 0, display_order INTEGER NOT NULL DEFAULT 2147483647, \
        PRIMARY KEY(source_id, remote_book_id), FOREIGN KEY(source_id, remote_book_id) \
        REFERENCES books(source_id, remote_book_id) ON UPDATE NO ACTION ON DELETE CASCADE)
        """,
        """
        CREATE TABLE local_book_tags (source_id TEXT NOT NULL, remote_book_id TEXT NOT NULL, \
        normalized_tag TEXT NOT NULL, display_tag TEXT NOT NULL, \
        PRIMARY KEY(source_id, remote_book_id, normalized_tag), FOREIGN KEY(source_id, remote_book_id) \
        REFERENCES library_entries(source_id, remote_book_id) ON UPDATE NO ACTION ON DELETE CASCADE)
        """,
        """
        CREATE TABLE manual_collection_memberships (collection_id TEXT NOT NULL, source_id TEXT NOT NULL, \
        remote_book_id TEXT NOT NULL, added_at_epoch_second INTEGER NOT NULL, added_at_nano INTEGER NOT NULL, \
        display_order INTEGER NOT NULL, PRIMARY KEY(collection_id, source_id, remote_book_id), \
        FOREIGN KEY(collection_id) REFERENCES collections(collection_id) ON UPDATE NO ACTION ON DELETE CASCADE, \
        FOREIGN KEY(source_id, remote_book_id) REFERENCES library_entries(source_id, remote_book_id) \
        ON UPDATE NO ACTION ON DELETE CASCADE)
        """,
        """
        CREATE INDEX index_manual_collection_memberships_source_id_remote_book_id \
        ON manual_collection_memberships(source_id, remote_book_id)
        """,
        """
        CREATE TABLE reading_progress (source_id TEXT NOT NULL, remote_book_id TEXT NOT NULL, \
        content_id TEXT NOT NULL, revision TEXT, block_id TEXT, text_anchor_digest TEXT, \
        character_offset INTEGER, chapter_progress REAL, book_progress REAL, \
        updated_at_epoch_second INTEGER NOT NULL, updated_at_nano INTEGER NOT NULL, \
        PRIMARY KEY(source_id, remote_book_id), FOREIGN KEY(source_id, remote_book_id) \
        REFERENCES books(source_id, remote_book_id) ON UPDATE NO ACTION ON DELETE CASCADE)
        """,
        """
        CREATE TABLE remote_library_reconciliation (id TEXT NOT NULL, source_id TEXT NOT NULL, \
        remote_book_id TEXT NOT NULL, package_digest TEXT NOT NULL, package_version TEXT NOT NULL, \
        capability_set_fingerprint TEXT NOT NULL, registry_generation INTEGER NOT NULL, state TEXT NOT NULL, \
        created_at_epoch_second INTEGER NOT NULL, updated_at_epoch_second INTEGER NOT NULL, \
        diagnostic_id TEXT, PRIMARY KEY(id))
        """,
        """
        CREATE INDEX index_remote_library_reconciliation_source_id_remote_book_id \
        ON remote_library_reconciliation(source_id, remote_book_id)
        """,
        """
        CREATE TABLE source_availability (source_id TEXT NOT NULL, verified_version TEXT, \
        available INTEGER NOT NULL, generation INTEGER NOT NULL, PRIMARY KEY(source_id))
        """,
        """
        CREATE TABLE source_remote_policy (source_id TEXT NOT NULL, \
        trusted_publisher_fingerprint TEXT NOT NULL, capability_set_fingerprint TEXT NOT NULL, \
        approved_origin TEXT NOT NULL, add_writeback_enabled INTEGER NOT NULL, \
        first_import_prompt_dismissed INTEGER NOT NULL, PRIMARY KEY(source_id))
        """,
        """
        CREATE TABLE browsing_history (source_id TEXT NOT NULL, remote_book_id TEXT NOT NULL, \
        last_viewed_at_epoch_second INTEGER NOT NULL, last_viewed_at_nano INTEGER NOT NULL, \
        PRIMARY KEY(source_id, remote_book_id), FOREIGN KEY(source_id, remote_book_id) \
        REFERENCES books(source_id, remote_book_id) ON UPDATE NO ACTION ON DELETE CASCADE)
        """,
        """
        CREATE TABLE import_sessions (id TEXT NOT NULL, kind TEXT NOT NULL, plan_digest TEXT NOT NULL, \
        normalized_plan_path TEXT NOT NULL, status TEXT NOT NULL, \
        source_created_at_epoch_second INTEGER NOT NULL, started_at_epoch_second INTEGER NOT NULL, \
        completed_at_epoch_second INTEGER, preference_patch_json TEXT NOT NULL, summary_json TEXT, \
        PRIMARY KEY(id))
        """,
        """
        CREATE TABLE import_warnings (session_id TEXT NOT NULL, ordinal INTEGER NOT NULL, \
        safe_code TEXT NOT NULL, safe_record_ref TEXT, field_name TEXT, severity TEXT NOT NULL, \
        PRIMARY KEY(session_id, ordinal), FOREIGN KEY(session_id) REFERENCES import_sessions(id) \
        ON UPDATE NO ACTION ON DELETE CASCADE)
        """,
        """
        CREATE TABLE search_history (source_id TEXT NOT NULL, normalized_query TEXT NOT NULL, \
        display_query TEXT NOT NULL, last_used_at_epoch_second INTEGER NOT NULL, \
        last_used_at_nano INTEGER NOT NULL, PRIMARY KEY(source_id, normalized_query))
        """,
        """
        CREATE TABLE smart_rules (collection_id TEXT NOT NULL, rule_version INTEGER NOT NULL, \
        ast_json TEXT NOT NULL, compiled_projection_version INTEGER NOT NULL, PRIMARY KEY(collection_id), \
        FOREIGN KEY(collection_id) REFERENCES collections(collection_id) ON UPDATE NO ACTION ON DELETE CASCADE)
        """,
        """
        CREATE TABLE subscription_drafts (collection_id TEXT NOT NULL, mode TEXT NOT NULL, \
        source_scope_json TEXT NOT NULL, query_json TEXT NOT NULL, enabled INTEGER NOT NULL, \
        import_session_id TEXT, PRIMARY KEY(collection_id), FOREIGN KEY(collection_id) \
        REFERENCES collections(collection_id) ON UPDATE NO ACTION ON DELETE CASCADE)
        """
    ]
}
