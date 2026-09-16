# frozen_string_literal: true

require "rails_helper"

RSpec.describe AdminController do
  include SessionSupport

  describe "#disbursement_process" do
    render_views

    it "renders mission statements for the source and destination events" do
      admin = create(:user, :make_admin)
      source_event = create(:event, description: "Source mission statement")
      destination_event = create(:event, description: "Destination mission statement")
      disbursement = create(:disbursement, source_event:, event: destination_event)

      create_session(admin, verified: true)

      get :disbursement_process, params: { id: disbursement.id }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Source mission statement")
      expect(response.body).to include("Destination mission statement")
    end
  end

  describe "#ach_start_approval" do
    render_views

    it "renders the ach transfer event's mission statement" do
      admin = create(:user, :make_admin)
      event = create(:event, :with_positive_balance, description: "Money wiring mission statement")
      ach_transfer = create(:ach_transfer, event:)

      create_session(admin, verified: true)

      get :ach_start_approval, params: { id: ach_transfer.id }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Money wiring mission statement")
    end
  end

  describe "#transaction" do
    render_views

    let(:admin) { create(:user, :make_admin) }
    let(:original_event) { create(:event, name: "Originally mapped event") }
    let(:new_event) { create(:event, name: "Remapped event") }

    before { create_session(admin, verified: true) }

    def settled_three_months_ago
      travel_to(3.months.ago) { create(:canonical_transaction, transaction_source: create(:raw_plaid_transaction)) }
    end

    def set_event(canonical_transaction, event)
      CanonicalTransactionService::SetEvent.new(
        canonical_transaction_id: canonical_transaction.id,
        event_id: event&.id,
        user: admin
      ).run
    end

    it "shows the transaction's initial mapping, even when it was made automatically" do
      canonical_transaction = settled_three_months_ago
      travel_to(3.months.ago) { create(:canonical_event_mapping, canonical_transaction:, event: original_event) }

      get :transaction, params: { id: canonical_transaction.id }

      expect(response.body).to include("Mapping History")
      expect(response.body).to include("Originally mapped event")
    end

    it "shows the initial automatic mapping even after it has been remapped", versioning: true do
      canonical_transaction = settled_three_months_ago
      travel_to(3.months.ago) { create(:canonical_event_mapping, canonical_transaction:, event: original_event) }
      set_event(canonical_transaction, new_event)

      get :transaction, params: { id: canonical_transaction.id }

      expect(response.body).to include("Originally mapped event")
      expect(response.body.index("Originally mapped event")).to be < response.body.index("Remapped event")
      expect(response.body).to include("first mapped to &quot;Originally mapped event&quot; back in #{3.months.ago.strftime("%B %Y")}")
    end

    it "keeps the earlier mapping when mapping to a wire changes the transaction's HCB code", versioning: true do
      canonical_transaction = settled_three_months_ago
      travel_to(3.months.ago) { create(:canonical_event_mapping, canonical_transaction:, event: original_event) }
      original_hcb_code = canonical_transaction.reload.hcb_code

      # Mapping to a wire or Wise transfer repoints the transaction at the transfer's own HCB code.
      set_event(canonical_transaction, new_event)
      canonical_transaction.update!(hcb_code: "HCB-400-wire-transfer")
      HcbCode.find_or_create_by!(hcb_code: "HCB-400-wire-transfer")

      get :transaction, params: { id: canonical_transaction.id }

      expect(response.body).to include("Originally mapped event")
      expect(response.body).to include("Remapped event")
      expect(response.body).to include(original_hcb_code)
      expect(response.body).to include("HCB-400-wire-transfer")
    end

    it "shows every event the transaction has been mapped to, oldest first" do
      canonical_transaction = settled_three_months_ago
      travel_to(3.months.ago) { set_event(canonical_transaction, original_event) }
      set_event(canonical_transaction, new_event)

      get :transaction, params: { id: canonical_transaction.id }

      expect(response.body.index("Originally mapped event")).to be < response.body.index("Remapped event")
    end

    it "warns about the month of the first mapping, not the most recent one" do
      canonical_transaction = settled_three_months_ago
      travel_to(3.months.ago) { set_event(canonical_transaction, original_event) }
      set_event(canonical_transaction, new_event)

      get :transaction, params: { id: canonical_transaction.id }

      expect(response.body).to include("first mapped to &quot;Originally mapped event&quot; back in #{3.months.ago.strftime("%B %Y")}")
      expect(response.body).to include("REMAP #{canonical_transaction.id}")
    end

    it "warns when a transaction mapped in a previous month has since been unmapped" do
      canonical_transaction = settled_three_months_ago
      travel_to(3.months.ago) { set_event(canonical_transaction, original_event) }
      set_event(canonical_transaction, nil)

      get :transaction, params: { id: canonical_transaction.id }

      expect(canonical_transaction.reload.canonical_event_mapping).to be_nil
      expect(response.body).to include("Are you absolutely sure you want to map this transaction?")
    end

    describe "emailing accounting after a warned-about remap" do
      let(:sierra) { create(:user) }
      let(:lucy) { create(:user) }

      before do
        allow(User).to receive(:find_by_public_id).and_call_original
        allow(User).to receive(:find_by_public_id).with("usr_JptgR1").and_return(sierra)
        allow(User).to receive(:find_by_public_id).with("usr_MVtap3").and_return(lucy)
      end

      it "emails Sierra and Lucy with the mapping history when a closed-month mapping is remapped", versioning: true do
        canonical_transaction = settled_three_months_ago
        travel_to(3.months.ago) { create(:canonical_event_mapping, canonical_transaction:, event: original_event) }

        expect do
          perform_enqueued_jobs { post :set_event, params: { id: canonical_transaction.id, event_id: new_event.id } }
        end.to change { ActionMailer::Base.deliveries.count }.by(1)

        email = ActionMailer::Base.deliveries.last
        expect(email.to).to contain_exactly(sierra.email, lucy.email)
        expect(email.subject).to include("Transaction ##{canonical_transaction.id}")
        expect(email.body.encoded).to include("Originally mapped event")
        expect(email.body.encoded).to include("Remapped event")
        expect(email.body.encoded).to include(3.months.ago.strftime("%B %Y"))
      end

      it "doesn't email when the transaction was first mapped this month", versioning: true do
        canonical_transaction = create(:canonical_transaction, transaction_source: create(:raw_plaid_transaction))
        create(:canonical_event_mapping, canonical_transaction:, event: original_event)

        expect do
          perform_enqueued_jobs { post :set_event, params: { id: canonical_transaction.id, event_id: new_event.id } }
        end.not_to(change { ActionMailer::Base.deliveries.count })
      end

      it "doesn't email when a never-mapped transaction is mapped for the first time", versioning: true do
        canonical_transaction = settled_three_months_ago

        expect do
          perform_enqueued_jobs { post :set_event, params: { id: canonical_transaction.id, event_id: new_event.id } }
        end.not_to(change { ActionMailer::Base.deliveries.count })
      end
    end

    it "doesn't warn when the transaction has never been mapped" do
      canonical_transaction = settled_three_months_ago

      get :transaction, params: { id: canonical_transaction.id }

      expect(response.body).not_to include("Mapping History")
      expect(response.body).not_to include("REMAP #{canonical_transaction.id}")
    end

    it "doesn't warn when the transaction was first mapped this month" do
      canonical_transaction = create(:canonical_transaction, transaction_source: create(:raw_plaid_transaction))
      create(:canonical_event_mapping, canonical_transaction:, event: original_event)
      set_event(canonical_transaction, new_event)

      get :transaction, params: { id: canonical_transaction.id }

      expect(response.body).to include("Mapping History")
      expect(response.body).not_to include("REMAP #{canonical_transaction.id}")
    end
  end
end
