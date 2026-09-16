# frozen_string_literal: true

# Reconstructs every event mapping a canonical transaction has ever had.
module HasMappingHistory
  extend ActiveSupport::Concern

  # Every event this transaction has been mapped to, including CanonicalEventMapping
  # and initial automatic mapping (if applicable)
  def mapping_history
    history = Ahoy::Event
              .where("name = ? and (properties->'canonical_transaction'->>'id')::int = ?", ::SystemEventService::Write::SettledTransactionMapped::NAME, id)
              .map do |ahoy_event|
      {
        time: ahoy_event.time,
        user_id: ahoy_event.properties.dig("user", "id"),
        event_id: ahoy_event.properties.dig("canonical_event_mapping", "event_id"),
        canonical_event_mapping_id: ahoy_event.properties.dig("canonical_event_mapping", "id")
      }
    end

    if canonical_event_mapping && history.none? { |m| m[:canonical_event_mapping_id] == canonical_event_mapping.id }
      history << {
        time: canonical_event_mapping.created_at,
        user_id: canonical_event_mapping.user_id,
        event_id: canonical_event_mapping.event_id,
        canonical_event_mapping_id: canonical_event_mapping.id
      }
    end

    hcb_code_changes = versions.where("object_changes -> 'hcb_code' is not null")
                               .map { |version| { time: version.created_at, before: version.object_changes["hcb_code"].first, after: version.object_changes["hcb_code"].last } }
    hcb_codes = HcbCode.where(hcb_code: (hcb_code_changes.flat_map { |change| change.values_at(:before, :after) } << hcb_code).compact.uniq).index_by(&:hcb_code)

    PaperTrail::Version.where(item_type: "HcbCode", item_id: hcb_codes.values.map(&:id))
                       .where("object_changes -> 'event_id' is not null")
                       .where(created_at: created_at..)
                       .find_each do |version|
      event_id = version.object_changes["event_id"].last
      next if history.any? { |m| m[:event_id] == event_id }

      history << {
        time: version.created_at,
        user_id: version.whodunnit&.match?(/\A\d+\z/) ? version.whodunnit.to_i : nil,
        event_id:
      }
    end

    events = Event.where(id: history.filter_map { |m| m[:event_id] }).index_by(&:id)
    users = User.where(id: history.filter_map { |m| m[:user_id] }).index_by(&:id)

    history.sort_by { |m| m[:time] }.map do |m|
      # Mapping to a wire or Wise transfer sets the event and rewrites the hcb_code in one action, so
      # a change moments after a mapping belongs to that mapping.
      change = hcb_code_changes.reverse.find { |c| c[:time] <= m[:time] + 5.seconds }

      {
        time: m[:time],
        user: users[m[:user_id]],
        event: events[m[:event_id]],
        event_id: m[:event_id],
        automatic: m[:user_id].nil?,
        hcb_code: hcb_codes[change ? change[:after] : (hcb_code_changes.first&.dig(:before) || hcb_code)]
      }
    end
  end

end
